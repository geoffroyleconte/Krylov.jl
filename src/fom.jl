# An implementation of FOM for the solution of the square linear system Ax = b.
#
# This method is described in
#
# Y. Saad, Krylov subspace methods for solving unsymmetric linear systems.
# Mathematics of computation, Vol. 37(155), pp. 105--126, 1981.
#
# Alexis Montoison, <alexis.montoison@polymtl.ca>
# Montreal, December 2018.

export fom, fom!

"""
    (x, stats) = fom(A, b::AbstractVector{T};
                     M=I, N=I, atol::T=√eps(T), rtol::T=√eps(T),
                     reorthogonalization::Bool=false, itmax::Int=0,
                     memory::Int=20, verbose::Int=0, history::Bool=false) where T <: AbstractFloat

Solve the linear system Ax = b using FOM method.

FOM algorithm is based on the Arnoldi process and a Galerkin condition.

This implementation allows a left preconditioner M and a right preconditioner N.
- Left  preconditioning : M⁻¹Ax = M⁻¹b
- Right preconditioning : AN⁻¹u = b with x = N⁻¹u
- Split preconditioning : M⁻¹AN⁻¹u = M⁻¹b with x = N⁻¹u

#### Reference

* Y. Saad, *Krylov subspace methods for solving unsymmetric linear systems*, Mathematics of computation, Vol. 37(155), pp. 105--126, 1981.
"""
function fom(A, b :: AbstractVector{T}; memory :: Int=20, kwargs...) where T <: AbstractFloat
  solver = FomSolver(A, b, memory)
  fom!(solver, A, b; kwargs...)
  return (solver.x, solver.stats)
end

function fom!(solver :: FomSolver{T,S}, A, b :: AbstractVector{T};
              M=I, N=I, atol :: T=√eps(T), rtol :: T=√eps(T),
              reorthogonalization :: Bool=false, itmax :: Int=0,
              verbose :: Int=0, history :: Bool=false) where {T <: AbstractFloat, S <: DenseVector{T}}

  m, n = size(A)
  m == n || error("System must be square")
  length(b) == m || error("Inconsistent problem size")
  (verbose > 0) && @printf("FOM: system of size %d\n", n)

  # Check M == Iₙ and N == Iₙ
  MisI = (M == I)
  NisI = (N == I)

  # Check type consistency
  eltype(A) == T || error("eltype(A) ≠ $T")
  ktypeof(b) == S || error("ktypeof(b) ≠ $S")
  MisI || (eltype(M) == T) || error("eltype(M) ≠ $T")
  NisI || (eltype(N) == T) || error("eltype(N) ≠ $T")

  # Set up workspace.
  allocate_if(!MisI, solver, :q, S, n)
  allocate_if(!NisI, solver, :p, S, n)
  x, w, V, z = solver.x, solver.w, solver.V, solver.z
  l, U, stats = solver.l, solver.U, solver.stats
  rNorms = stats.residuals
  reset!(stats)
  q  = MisI ? w : solver.q
  r₀ = MisI ? b : solver.q

  # Initial solution x₀ and residual r₀.
  x .= zero(T)            # x₀
  MisI || mul!(r₀, M, b)  # M⁻¹(b - Ax₀)
  β = @knrm2(n, r₀)       # β = ‖r₀‖₂
  rNorm = β
  history && push!(rNorms, β)
  if β == 0
    stats.solved, stats.inconsistent = true, false
    stats.status = "x = 0 is a zero-residual solution"
    return solver
  end

  iter = 0
  itmax == 0 && (itmax = 2*n)

  ε = atol + rtol * rNorm
  (verbose > 0) && @printf("%5s  %7s\n", "k", "‖rₖ‖")
  display(iter, verbose) && @printf("%5d  %7.1e\n", iter, rNorm)

  # Initialize workspace.
  nr = 0           # Number of coefficients stored in Uₖ.
  mem = length(l)  # Memory
  for i = 1 : mem
    V[i] .= zero(T)  # Orthogonal basis of Kₖ(M⁻¹AN⁻¹, M⁻¹b).
  end
  l .= zero(T)  # Lower unit triangular matrix Lₖ.
  U .= zero(T)  # Upper triangular matrix Uₖ.
  z .= zero(T)  # Solution of Lₖzₖ = βe₁.

  # Initial ζ₁ and V₁.
  z[1] = β
  @. V[1] = r₀ / rNorm

  # Stopping criterion
  solved = rNorm ≤ ε
  tired = iter ≥ itmax
  status = "unknown"

  while !(solved || tired)

    # Update iteration index
    iter = iter + 1

    # Update workspace if more storage is required
    if iter > mem
      for i = 1 : iter
        push!(U, zero(T))
      end
      push!(l, zero(T))
      push!(z, zero(T))
    end

    # Continue the Arnoldi process.
    p = NisI ? V[iter] : solver.p
    NisI || mul!(p, N, V[iter])  # p ← N⁻¹vₖ
    mul!(w, A, p)                # w ← AN⁻¹vₖ
    MisI || mul!(q, M, w)        # q ← M⁻¹AN⁻¹vₖ
    for i = 1 : iter
      U[nr+i] = @kdot(n, V[i], q)    # hᵢₖ = qᵀvᵢ
      @kaxpy!(n, -U[nr+i], V[i], q)  # q ← q - hᵢₖvᵢ
    end

    # Reorthogonalization of the Krylov basis.
    if reorthogonalization
      for i = 1 : iter
        Htmp = @kdot(n, V[i], q)
        U[nr+i] += Htmp
        @kaxpy!(n, -Htmp, V[i], q)
      end
    end

    # Compute hₖ₊₁.ₖ
    Hbis = @knrm2(n, q)  # hₖ₊₁.ₖ = ‖vₖ₊₁‖₂

    # Update the LU factorization of Hₖ.
    if iter ≥ 2
      for i = 2 : iter
        # uᵢ.ₖ ← hᵢ.ₖ - lᵢ.ᵢ₋₁ * uᵢ₋₁.ₖ
        U[nr+i] = U[nr+i] - l[i-1] * U[nr+i-1]
      end
      # ζₖ = -lₖ.ₖ₋₁ * ζₖ₋₁
      z[iter] = - l[iter-1] * z[iter-1]
    end
    # lₖ₊₁.ₖ = hₖ₊₁.ₖ / uₖ.ₖ
    l[iter] = Hbis / U[nr+iter]

    # Update residual norm estimate.
    # ‖ M⁻¹(b - Axₖ) ‖₂ = hₖ₊₁.ₖ * |ζₖ / uₖ.ₖ|
    rNorm = Hbis * abs(z[iter] / U[nr+iter])
    history && push!(rNorms, rNorm)

    # Update the number of coefficients in Uₖ
    nr = nr + iter

    # Update stopping criterion.
    solved = rNorm ≤ ε
    tired = iter ≥ itmax
    display(iter, verbose) && @printf("%5d  %7.1e\n", iter, rNorm)

    # Compute vₖ₊₁.
    if !(solved || tired)
      if iter ≥ mem
        push!(V, S(undef, n))
      end
      @. V[iter+1] = q / Hbis  # hₖ₊₁.ₖvₖ₊₁ = q
    end
  end
  (verbose > 0) && @printf("\n")

  # Hₖyₖ = βe₁ ⟺ LₖUₖyₖ = βe₁ ⟺ Uₖyₖ = zₖ.
  # Compute yₖ by solving Uₖyₖ = zₖ with backward substitution.
  y = z  # yᵢ = zᵢ
  for i = iter : -1 : 1
    pos = nr + i - iter
    for j = iter : -1 : i+1
      y[i] = y[i] - U[pos] * y[j]  # yᵢ ← yᵢ - uᵢⱼyⱼ
      pos = pos - j + 1
    end
    y[i] = y[i] / U[pos]  # yᵢ ← yᵢ / rᵢᵢ
  end

  # Form xₖ = N⁻¹Vₖyₖ
  for i = 1 : iter
    @kaxpy!(n, y[i], V[i], x)
  end
  if !NisI
    solver.p .= x
    mul!(x, N, solver.p)
  end

  status = tired ? "maximum number of iterations exceeded" : "solution good enough given atol and rtol"

  # Update stats
  stats.solved = solved
  stats.inconsistent = false
  stats.status = status
  return solver
end