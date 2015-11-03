# This file is a part of JuliaFEM.
# License is MIT: see https://github.com/JuliaFEM/JuliaFEM.jl/blob/master/LICENSE.md

type Basis <: ContinuousField
    basis :: Function
    dbasisdxi :: Function
end

""" Evaluate basis. """
function Base.call(basis::Basis, xi::Vector, time::Number=0.0)
    basis.basis(xi)  # passing time does not make much sense actually for this...
end

""" Evaluate gradient of basis. This need geometry information to calculate Jacobian. """
function Base.call(basis::Basis, geometry::Increment, xi::Vector,
                   ::Type{Val{:grad}})
    dbasis = basis.dbasisdxi(xi)
    J = sum([dbasis[:,i]*geometry[i]' for i=1:length(geometry)])
    grad = inv(J)*dbasis
    return grad
end

### INTERPOLATION IN SPATIAL DOMAIN ###

""" Interpolate increment in spatial domain using Basis. """
function Base.call(basis::Basis, increment::Increment, xi::Vector)
    basis = basis.basis(xi)
    sum([basis[i]*increment[i] for i=1:length(increment)])
end

""" Return gradient of increment in spatial domain using Basis.. """
function Base.call(basis::Basis, geometry::Increment, field::Increment,
                   xi::Vector, ::Type{Val{:grad}})
    grad = basis(geometry, xi, Val{:grad})
    gradf = sum([grad[:,i]*field[i]' for i=1:length(field)])'
    return gradf
end

### INTERPOLATION IN TIME DOMAIN ###

""" Interpolate discrete field in time domain. Return Increment. """
function Base.call(field::DiscreteField, time::Number,
                   time_extrapolation::Symbol=:linear,
                   time_interpolation::Symbol=:linear)

    # special cases, only 1 timestep defined or time = -Inf -> return first ts
    if (length(field) == 1) || (time == -Inf)
        return field[1][end]
    end

    # special case, time = +Inf -> return last ts
    if time == +Inf
        return field[end][end]
    end

    # very likely we are always near some defined timestep, usually field
    # defined only on t = 0.0, test neighbourhood for timesteps
    for i=1:length(field)
        if isapprox(field[i].time, time)
            return field[i][end]
        end
    end

    # special case: out of time domain in positive direction, very likely
    # to happen in incremental constitutive models
    if time > field[end].time
        if time_extrapolation == :constant
            # constant time extrapolation, return last field
            return field[end][end]
        else
            # multiple fields, pick last and second last and do linear interpolation
            f1 = field[end-1]
            f2 = field[end]
            dt = abs(f2.time - f1.time)
            i1 = f1[end]
            i2 = f2[end]
            di = i2 - i1
            increment = Increment(i2 + di./dt * (time-f2.time))
            return increment
        end
    end

    # special case: out of time domain in negative direction
    if time < field[1].time
        if time_extrapolation == :constant
            # constant time extrapolation, return first field
            return field[1][end]
        else
            # multiple fields, pick first and second and do linear interpolation
            f1 = field[1]
            f2 = field[2]
            dt = abs(f2.time - f1.time)
            i1 = f1[end]
            i2 = f2[end]
            di = i2 - i1
            increment = Increment(i1 - di./dt * (f1.time - time))
            return increment
        end
    end

    # find correct bin and perform interpolation
    i = length(field)
    while field[i].time >= time
        i -= 1
    end

    if time_interpolation == :linear
        t1 = field[i].time
        t2 = field[i+1].time
        inc1 = field[i][end]
        inc2 = field[i+1][end]
        dt = abs(t2 - t1)
        t = (time-t1)/dt
        increment = Increment((1-t)*inc1 + t*inc2)
        return increment
    end

    if time_interpolation == :constant
        # nearest neightbour interpolation, i.e. pick nearest defined field
        t1 = field[i].time
        t2 = field[i+1].time
        dt1 = abs(t1-time)
        dt2 = abs(t2-time)
        if dt1 < dt2
            return field[i][end]
        else
            return field[i+1][end]
        end
    end

end

""" Interpolate time derivative of field in some time t. This assumes linear
interpolation in time which is then differentiated.

Parameters
----------
field
    Discrete field to interpolate. Must have timesteps and increments defined
time
    Time to interpolate.
derivative
    set Val{:diff} to activate this function

"""
function Base.call(field::DiscreteField, time::Number, ::Type{Val{:diff}})

    # FieldSet -> Field -> TimeStep -> Increment -> data

    if length(field) == 1
        # just one timestep, time derivative cannot be evaluated.
        error("Field length = $(length(field)), cannot evaluate time derivative")
    end

    function eval_field(i, j)
        t1 = field[i]
        t2 = field[j]
        J = abs(t2.time - t1.time)
        t = (time-t1.time)/J
        result = 1/J*(-1*t1[end] + 1*t2[end])
        return Increment(result)
    end

    # special cases, +Inf, -Inf, ~0.0
    if (time > field[end].time) || isapprox(time, field[end].time)
        return eval_field(endof(field)-1, endof(field))
    end

    if (time < field[1].time) || isapprox(time, field[1].time)
        return eval_field(1, 2)
    end

    # search for a correct "bin" between time steps
    i = length(field)
    while (field[i].time > time) && !isapprox(field[i].time, time)
        i -= 1
    end

    if isapprox(field[i].time, time)
        # This is the hard case, maybe discontinuous time
        # derivative if linear approximation.
        # we are on the "mid node" in time axis
        field1 = eval_field(i-1,i)
        field2 = eval_field(i,i+1)
        return 1/2*(field1 + field2)
    end

    return eval_field(i, i+1)

end



### ELEMENT FIELD BASIS = ELEMENT BASIS + FIELD
#=
""" Here we add field we are wanting to interpolate with ElementBasis. """
type ElementFieldBasis <: Basis
    element_basis :: ElementBasis
    field :: DiscreteField
    time_extrapolation :: Symbol
    time_interpolation :: Symbol
end

function Basis(basis::Function, dbasisdxi::Function, field::DiscreteField,
               time_extrapolation=:linear, time_interpolation=:linear)
    element_basis = ElementBasis(basis, dbasisdxi)
    return ElementFieldBasis(element_basis, field, time_extrapolation,
                             time_interpolation)
end

function Base.call(basis::ElementFieldBasis, xi::Vector, time::Number)
    increment = basis.field(time, basis.time_extrapolation, basis.time_interpolation)
    return basis.element_basis(increment, xi)
end
=#


### ELEMENT GRADIENT BASIS = ELEMENT BASIS + GEOMETRY
#=
""" Gradient of ElementBasis, needs geometry information. """
type ElementGradientBasis <: Basis
    element_basis :: ElementBasis
    geometry :: DiscreteField
    time_extrapolation :: Symbol
    time_interpolation :: Symbol
end

function grad(N::ElementBasis, f::ElementFieldBasis, X::ElementFieldBasis)
    f.time_extrapolation == X.time_extrapolation || error("interpolation mismatch")
    f.time_interpolation == X.time_interpolation || error("interpolation mismatch")
    dN = ElementGradientBasis(N, X.field, f.time_extrapolation, f.time_interpolation)
    dfdX = ElementFieldGradientBasis(dN, f.field, f.time_extrapolation, f.time_interpolation)
    return dfdX
end

function grad(N::ElementBasis, f::DiscreteField, X::DiscreteField)
    dN = ElementGradientBasis(N, X)
    dfdX = ElementFieldGradientBasis(dN, f)
end

function ElementGradientBasis(element_basis::ElementBasis, geometry::DiscreteField)
    return ElementGradientBasis(element_basis, geometry, :linear, :linear)
end
=#

### ELEMENT FIELD GRADIENT BASIS = ELEMENT GRADIENT BASIS + FIELD
#=
""" Gradient of ElementFieldBasis, needs field to interpolate. """
type ElementFieldGradientBasis <: Basis
    element_gradient_basis :: ElementGradientBasis
    field :: DiscreteField
    time_extrapolation :: Symbol
    time_interpolation :: Symbol
end

function ElementFieldGradientBasis(element_gradient_basis::ElementGradientBasis,
                                   field::DiscreteField)
    return ElementFieldGradientBasis(element_gradient_basis, field, :linear, :linear)
end
=#

### INTERPOLATION IN TIME DOMAIN ###

