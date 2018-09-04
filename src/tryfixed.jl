"""
tryfixed(x, y1, y2, ...)
x ⩢ y1 ⩢ y2 ...

Test if a number `x` is equal to any of the numbers `y1`, `y2`, ..., and in that
case return `Fixed(y)`. Otherwise, or if `x` is already a `Fixed` number, `x is
returned unchanged.

The inferred return type will typically be a small `Union`, which Julia
can handle efficiently.

This function can be used to call specialized methods for certain input values.
For example, `f(x, y ⩢ 0)` will call `f(x, y)` if `y` is nonzero, but
`f(x, Fixed(0))` if y is zero. This is useful if it enables optimizations that
outweigh the cost of branching.

NOTE: When the list of y-values is longer than one, y1, y2, ... must be `Fixed`
numbers, or inferrence will not work. (In which case `tryfixed` is not more
efficient than `Fixed(x)`.)
"""
#The numbers `y1`, `y2`, ..., or the range `r` should be such that they can be
#computed at inference. I.e. they should be constructed using literals, `Fixed`
#numbers, and other constants that are deducible from types types.

@inline ⩢(x, y) = tryfixed(x,y)
@inline tryfixed(x::Fixed, ys::Number...) = x
@inline tryfixed(x::Fixed, y::Fixed) = x #disambig
@inline tryfixed(x::Number) = x
@inline tryfixed(x::Number, y::Fixed) = x==y ? y : x
@inline tryfixed(x::Number, y::Number) = tryfixed(x, Fixed(y))
@inline tryfixed(x::Number, y::Number, ys::Number...) = tryfixed(tryfixed(x, y), ys...)

@inline tryfixed(x::Number, t::T) where {T<:Tuple} = tryfixed(x, Fixed.(t)...)

"""
tryfixed(x, r)
Tests if an integer `x` is in the range `r`, and if so, returns a `Fixed`
integer from the range. (Otherwise, `x` is returned unchanged.)

NOTE: The range must be completely fixed, or inferrence will not work.
"""
@inline tryfixed(x::FixedInteger, r::OrdinalRange{<:Integer, <:Integer}) = x
@inline tryfixed(x::Integer, r::OrdinalRange{<:Integer, <:Integer}) =
    tryfixed(x::Integer, FixedStepRange(Fixed(zeroth(r)), Fixed(step(r)), Fixed(length(r))))
@inline tryfixed(x::Integer, r::FixedStepRange{<:Integer, <:FixedInteger, <:FixedInteger, <:FixedInteger}) = x in r ? tofixed(x, r) : x
@inline tryfixed(x::Integer, r::UnitRange{<:Integer}) =
    tryfixed(x::Integer, FixedUnitRange(Fixed(zeroth(r)), Fixed(length(r))))
@inline tryfixed(x::Integer, r::FixedUnitRange{<:Integer, <:FixedInteger, <:FixedInteger}) = x in r ? tofixed(x, r) : x

#@inline tofixed(x::Integer, r::StepRange) = tofixed(x, FixedStepRange(Fixed(zeroth(r)), Fixed(step(r)), Fixed(lenght(r)))
#@inline tofixed(x::Integer, r::UnitRange) = tofixed(x, FixedUnitRange(Fixed(zeroth(r)), Fixed(lenght(r)))

"""
tofixed(x, r)
Returns a `Fixed` integer, equal to `x` from the range `r`. If no element in
`r` is equal to `x`, then the behaviour of this function is undefined.
"""
@inline tofixed(x::Fixed, r::OrdinalRange{<:Integer, <:Integer}) = x
@generated function tofixed(x::Integer, r::FixedStepRange{<:Integer, FixedInteger{Z}, FixedInteger{S}, FixedInteger{L}}) where {Z, S, L}
    quote
        Base.@_inline_meta
        $(tofixedexpr(Z, S, L))
    end
end
@generated function tofixed(x::Integer, r::FixedUnitRange{<:Integer, FixedInteger{Z}, FixedInteger{L}}) where {Z, L}
    quote
        Base.@_inline_meta
        $(tofixedexpr(Z, 1, L))
    end
end
function tofixedexpr(z, s, l)
    if l<=1
        :( FixedInteger{$(z+s)}() )
    else
        mid = l÷2
        :( $(s>0 ? :(<=) : :(>=))(x, $(z + s*mid)) ? $(tofixedexpr(z, s, mid)) : $(tofixedexpr(z+mid*s, s, l-mid)) )
    end
end

"Fixed(mod(x,y))"
@inline fixedmod(x, y::FixedInteger) = tofixed(mod(x,y), FixedUnitRange(Fixed(-1), y))
