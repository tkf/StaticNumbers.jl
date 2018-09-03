# For beenchmarking, use: julia -O3

# Note: I'd like to be able to do this with `view`s that result
# in fixed-size subarrays, but at the moment, those are still allocating.
# So passing ranges as separate arguments instead.

# Instead of Julia's `@inbounds` mechanism, we pass `inbounds` explicitly
# as a `FixedOrBool` parameter. This works even when functions are not inlined,
# and makes it easier to eliminate bounds-checking code when using the @code_llvm
# macro.
# It's ugly, but it saves a few nanoseconds...
# Probably future optimizations in Julia will eliminate the need for this.

module MatMatMulExample

using FixedNumbers
using StaticArrays
using LinearAlgebra

# Change this to `false` to enable bounds checking in every function.
const ftrue = Fixed(true)

# Fast, zero-size LinearIndices for Static matrices if we define:
# Base.axes(A::StaticArray) = map(FixedOneTo, size(A))

"A struct that stores the block size used in matmatmul"
struct BlockSize{M<:Integer,N<:Integer,K<:Integer}
    m::M
    n::N
    k::K
end

"A struct that stores the matrices and sizes used in matmul"
struct MulArgs{MA<:AbstractArray,MB<:AbstractArray,MC<:AbstractArray,M<:Integer,N<:Integer,K<:Integer}
    A::MA
    B::MB
    C::MC
    m::M
    n::N
    k::K
    function MulArgs(A::MA,B::MB,C::MC,m::M,n::N,k::K) where {MA<:AbstractArray,MB<:AbstractArray,MC<:AbstractArray,M<:Integer,N<:Integer,K<:Integer}
        @boundscheck begin
            (1:m,1:k) == axes(A) && (1:k,1:n) == axes(B) && (1:m,1:n) == axes(C) || throw(dimerr)
        end
        new{MA,MB,MC,M,N,K}(A,B,C,m,n,k)
    end
end
Base.@propagate_inbounds function MulArgs(A,B,C)
    (m,n) = size(C)
    k = size(A,2)
    # MulArgs(A,B,C,Fixed(m),Fixed(n),Fixed(k)) # Compiles for every size !
    MulArgs(A,B,C,m,n,k) # slower.
end
function MulArgs(A::StaticMatrix{m,k},B::StaticMatrix{k,n},C::StaticMatrix{m,n}) where {m,n,k}
    @inbounds MulArgs(A,B,C,Fixed(m),Fixed(n),Fixed(k))
end

"A version of size, which gives `FixedInteger`s for `StaticArray`s"
sz(A) = size(A)
sz(A::StaticArray) = Fixed.(size(A))
sz(A, d) = sz(A)[d]

const dimerr = DimensionMismatch("Incompatible matrix axes")
const aliaserr = ErrorException("Destination matrix cannot be one of inputs")
const rerr = DimensionMismatch("Subrange error.")

"""
Check that ranges are in bounds for `mymul`.
"""
@inline function checkmulbounds(ABC::MulArgs, mm::AbstractRange, nn::AbstractRange, kk::AbstractRange)
    1 <= first(mm) <= ABC.m &&
    1 <= last(mm) <= ABC.m &&
    1 <= first(nn) <= ABC.n &&
    1 <= last(nn) <= ABC.n &&
    1 <= first(kk) <= ABC.k &&
    1 <= last(kk) <= ABC.k || throw(rerr)
end

"""
C <- A*B + beta*C

If `inbounds` is `true` then no check is performed that matrix sizes match
block specifications. This can lead to memory corruption.
"""
function mymul!(C::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix,
                beta::Number, inbounds::FixedOrBool,
                mnk::BlockSize, mnks::BlockSize...)
    mymul!(MulArgs(A,B,C), beta::Number, inbounds, mnk, mnks...)
end

#const u4 = (0,1,2,3)
#const u4 = Fixed.((0,1,2,3))
const u4 = FixedUnitRange(Fixed(-1),Fixed(4))
#const u4 = Fixed.((0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15))

const U4 = Union{FixedInteger{0},FixedInteger{1},FixedInteger{2},FixedInteger{3}}

# Note: This is not typstable unless sizes of A, B, C are fixed.
@inline function mymul!(ABC::MulArgs,
                beta::Number, inbounds::FixedOrBool,
                mnk::BlockSize, mnks::BlockSize...)
    (tm, rm) = divrem(ABC.m, mnk.m)
    (tn, rn) = divrem(ABC.n, mnk.n)
    (tk, rk) = divrem(ABC.k, mnk.k)

    mymul!(ABC, beta, ftrue,
        tm, tn, tk,
#        tryfixed(rm, u4), tryfixed(rn, u4), tryfixed(rk, u4),
#        tryfixed(rm, u4...), tryfixed(rn, u4...), tryfixed(rk, u4...),
#        rm, rn, rk,
#        Fixed(rm), Fixed(rn), Fixed(rk),
#        Fixed(rm)::U4, Fixed(rn)::U4, Fixed(rk)::U4,
#        Fixed(rm)::FixedInteger, Fixed(rn)::FixedInteger, Fixed(rk)::FixedInteger,
        fixedmod(ABC.m, mnk.m), fixedmod(ABC.n, mnk.n), fixedmod(ABC.k, mnk.k),
        mnk.m, mnk.n, mnk.k,
        mnks...)
end

# C <- A*B
mymul!(C::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix, mnks::BlockSize...) = mymul!(C, A, B, Fixed(false), Fixed(false), mnks...)
mymul!(ABC::MulArgs, mnks::BlockSize...) = mymul!(ABC, Fixed(false), Fixed(false), mnks...)

function mymul!(ABC::MulArgs,
                beta::Number, inbounds::FixedOrBool,
                tm::Integer, tn::Integer, tk::Integer,
                rm::Integer, rn::Integer, rk::Integer,
                m::Integer, n::Integer, k::Integer)
    if !inbounds
        checkmulbounds(ABC, Base.OneTo(tm*m+rm), Base.OneTo(tn*n+rn), Base.OneTo(tk*k+rk))
    end
    for i=0:tm-1
        mm = i*m .+ FixedOneTo(m)
        mymul!(ABC, beta, ftrue, mm, tn, tk, rn, rk, n, k)
    end
    if rm>0
        mm = tm*m .+ FixedOneTo(rm)
        mymul!(ABC, beta, ftrue, mm, tn, tk, rn, rk, n, k)
    end
end

#C[mm,:] <- A[mm,:]*B + beta*C[mm,:]
function mymul!(ABC::MulArgs,
        beta::Number, inbounds::FixedOrBool,
        mm::AbstractUnitRange{<:Integer}, tn::Integer, tk::Integer,
        rn::Integer, rk::Integer, n::Integer, k::Integer)
    if !inbounds
        checkmulbounds(ABC, mm, Base.OneTo(tn*n+rn), Base.OneTo(tk*k+rk))
    end
    for j=0:tn-1
        nn = j*n .+ FixedOneTo(n)
        mymul!(ABC, beta, ftrue, mm, nn, tk, rk, k)
    end
    if rn>0
        nn = tn*n .+ FixedOneTo(rn)
        mymul!(ABC, beta, ftrue, mm, nn, tk, rk, k)
    end
end

# C[mm,nn] <- A[mm,:]*B[:,nn] + beta*C[mm,nn]
function mymul!(ABC::MulArgs,
        beta::Number, inbounds::FixedOrBool,
        mm::AbstractUnitRange{<:Integer}, nn::AbstractUnitRange{<:Integer},
        tk::Integer, rk::Integer, k::Integer)
    if !inbounds
        checkmulbounds(ABC, mm, nn, Base.OneTo(tk*k+rk))
    end
    X = beta * load(SMatrix, ABC.C, ABC.m, mm, nn, ftrue)
    for h=0:tk-1
        kk = h*k .+ FixedOneTo(k)
        X += load(SMatrix, ABC.A, ABC.m, mm, kk, ftrue) * load(SMatrix, ABC.B, ABC.k, kk, nn, ftrue)
    end
    if rk>0
        kk = tk*k .+ FixedOneTo(rk)
        X += load(SMatrix, ABC.A, ABC.m, mm, kk, ftrue) * load(SMatrix, ABC.B, ABC.k, kk, nn, ftrue)
    end
    store!(ABC.C, ABC.m, mm, nn, X, ftrue)
    return nothing
end

@generated function load(::Type{T}, C::AbstractMatrix, M::Integer,
        mm::FixedUnitRange{Int,IM,FixedInteger{m}},
        nn::FixedUnitRange{Int,IN,FixedInteger{n}},
        inbounds::FixedOrBool) where {T,IM,IN,m,n}
    a = Vector{Expr}()
    for j=1:n
        for i=1:m
            push!(a, :( C[k+$i+$(j-1)*M] ))
        end
    end
    return quote
        Base.@_inline_meta
        if !inbounds
             checkbounds(C, mm, nn)
        end
        k = M*zeroth(nn) + zeroth(mm)
        @inbounds T{m,n}($(Expr(:tuple, a...)))
    end
end

# # Note, reading into a transpose is slow. Probably best to read first,
# then transpose.

@generated function store!(C::AbstractMatrix, M::Integer,
        mm::FixedUnitRange{Int,IM,FixedInteger{m}},
        nn::FixedUnitRange{Int,IN,FixedInteger{n}},
        X::StaticMatrix{m,n}, inbounds::FixedOrBool) where {IM,IN,m,n}
    a = Vector{Expr}()
    for j=1:n
        for i=1:m
            push!(a, :( C[k+$i+$(j-1)*M] ))
        end
    end
    return quote
        Base.@_inline_meta
        if !inbounds
             checkbounds(C, mm, nn)
        end
        k = zeroth(mm)+zeroth(nn)*M
        @inbounds $(Expr(:tuple, a...)) = X.data
        nothing
    end
end

# TODO Transpose and Adjoint

end # module

using FixedNumbers
using StaticArrays
using LinearAlgebra
using BenchmarkTools

m=17
n=18
k=19

A = randn(m,k)
B = randn(k,n)
C = zeros(m,n)

MA = MMatrix{m,k}(A)
MB = MMatrix{k,n}(B)
MC = zeros(MMatrix{m,n})

ABC = MatMatMulExample.MulArgs(A,B,C)
MABC = MatMatMulExample.MulArgs(MA,MB,MC)

blk = MatMatMulExample.BlockSize(Fixed(4), Fixed(4), Fixed(2))

MatMatMulExample.mymul!(ABC, blk)

println("Relative inaccuracy compared to BLAS = ", maximum(abs.(C .-  Float64.(big.(A)*big.(B)))) / maximum(abs.(A*B .-  Float64.(big.(A)*big.(B)))))

println("mul!, ", BLAS.vendor())
display(@benchmark mul!($C, $A, $B) samples=10 evals=10000)
println()

println("mymul!, Matrix")
display(@benchmark MatMatMulExample.mymul!($ABC, $blk) samples=10 evals=10000)
println()

println("mymul!, MMatrix")
display(@benchmark MatMatMulExample.mymul!($MABC, $blk) samples=10 evals=10000)
println()
