using ArgParse
using MLDataUtils
using ForwardDiff
using Distances
using LinearAlgebra
using ReverseDiff
using AutoGrad
using Random
#using CuArrays
using Flux
using Flux.Tracker
using Flux: @epochs
using Base.Iterators: partition
using DelimitedFiles

arguments = ArgParseSettings()
@add_arg_table arguments begin
    "--input", "-i"
    help = "input file containing normalized OWL EL axioms; usually the output of Normalize.groovy"
    required = true
    "--output", "-o"
    help = "output file containing class, relation, and instance coordinates"
    required = true
    "--epochs", "-e"
    help = "number of epochs to train"
    arg_type = Int
    default = 1000
    "--lr", "-l"
    help = "learning rate"
    arg_type = Float64
    default = 0.01
    "--dim", "-d"
    help = "input dimensions"
    arg_type = Int
    default = 20
    "--gpu", "-g"
    action = :store_true
    help = "use GPU accelleration"
    "--margin", "-m"
    arg_type = Float64
    default = 0.1
    help = "margin parameter"
end
args = parse_args(ARGS, arguments)
if args["gpu"] == true
    using CuArrays
end

# Model parameters

LR = args["lr"] # learning rate
EPOCHS = args["epochs"] # number of epochs
DIM = args["dim"] # dimensionality of embeddings

# DL Constants; not valid indices of an array
BOTTOM = -1
TOP = -2

# Setting up the data

classes = Dict()
relations = Dict()
ccount = 1
rcount = 1

classes["owl:Nothing"] = BOTTOM
classes["<http://www.w3.org/2002/07/owl#Nothing>"] = BOTTOM
classes["owl:Thing"] = TOP
classes["<http://www.w3.org/2002/07/owl#Thing>"] = TOP

function filldict(x)
    global ccount
    if haskey(classes, x)
        return classes[x]
    else
        classes[x] = ccount
        ccount += 1
        return ccount - 1
    end
end

function rfilldict(x)
    global rcount
    if haskey(relations, x)
        return relations[x]
    else
        relations[x] = rcount
        rcount += 1
        return rcount - 1
    end
end

nf1 = Set()
nf2 = Set()
nf3 = Set()
nf4 = Set()

# Reading the file of normalized axioms (generated by Normalize.groovy)
open(args["input"]) do file
    for line in eachline(file)
        if (startswith(line, "SubClassOf")) # ignore subproperty axioms
            if occursin(r"ObjectIntersectionOf", line) # normal form 2
                m = match(r"(<.*>).*(<.*>).*(<.*>)", line) # 3 captures: C and D SubClassOf: E
                if m != nothing
                    c, d, e = map(filldict, m.captures)
                    push!(nf2, (c,d,e))
                end
            elseif occursin(r"SubClassOf.<[^\s]*>[\s]*<[^\s]*>.$", line) # normal form 1
                m = match(r"(<.*>).*(<.*>)", line) # 2 captures: C SubClassOf: D
                c,d = map(filldict, m.captures)
                push!(nf1, (c,d))
            elseif occursin(r"SubClassOf.ObjectSomeValuesFrom", line)  # normal form 4
                m = match(r"(<.*>).*(<.*>).*(<.*>)", line) # 3 captures: R some C SubClassOf: D
                r,c,d = m.captures
                c = filldict(c)
                d = filldict(d)
                r = rfilldict(r)
                push!(nf4, (c,d,r))
            elseif occursin(r"SubClassOf.<[^\s]*>[\s]*ObjectSomeValuesFrom", line)  # normal form 3
                m = match(r"(<.*>).*(<.*>).*(<.*>)", line) # 3 captures: C SubClassOf: R some D
                c,r,d = m.captures
                c = filldict(c)
                d = filldict(d)
                r = rfilldict(r)
                push!(nf3, (c,d,r))
            end
        end
    end
end

# there are now rcount-1 relations and ccount-1 classes; generate random embeddings; offload to GPU; make them trainable
cvec = rand(ccount-1, DIM + 1)
rvec = rand(rcount-1, DIM)
#cvec = rand(ccount-1, DIM + 1)
#rvec = rand(rcount-1, DIM)


@inline function radius(x::Array{AbstractFloat,1})
    return x[end]
end

@inline function centerpoint(x::Array{AbstractFloat,1})
    return x[1:end-1]
end

@inline function radius(x)
    return x[end]
end

@inline function centerpoint(x)
    return x[1:end-1]
end

# Radius: 0 if BOTTOM; infinity if TOP; otherwise to be optimized
@inline function radius(x::Int)
    if x == BOTTOM
        return 0
    elseif x == TOP
        return Inf
    else
        return radius(cvec[x,:])
    end
end

# Centerpoint: (0,...,0) if BOTTOM or TOP; otherwise to be optimized
@inline function centerpoint(x::Int)
    if x == BOTTOM
        return zeros(DIM)
    elseif x == TOP
        return zeros(DIM)
    else
        return centerpoint(cvec[x,:])
    end
end

@inline function v(x::Int)
    return rvec[x,:]
end

# loss functions that work with class indices
function loss1(c::Int, d::Int)
    return max(0, euclidean(centerpoint(c), centerpoint(d)) + abs(radius(c)) - abs(radius(d)) + args["margin"])
end
function loss1(x::Tuple{Int64,Int64})
    return loss1(x[1],x[2])
end
function loss1(x::Array{Tuple{Int64,Int64}})
    return loss1.(x)
end

function loss2(c1::Int, c2::Int, d::Int) # loss for c1 and c2 SubClassOf: d
    dist = euclidean(centerpoint(c1), centerpoint(c2))
    if dist > abs(radius(c1)) + abs(radius(c2)) # no solution, circles are separate
        rad = 0 # radius is 0
        cent = centerpoint(c1) + (centerpoint(c2) - centerpoint(c1)) / (dist - radius(c2)) # half-way between outer edges of the class
        # loss1 between the class with radius 0 and centerpoint half-way between c1 and c2, plus a penalty for the distance between c1 and c2
        return max(0, euclidean(cent, centerpoint(d)) + abs(rad) - abs(radius(d)) + (dist - abs(radius(c1)) - abs(radius(c2)) + args["margin"]))
    elseif dist < abs(radius(c1)-radius(c2)) # no solution, one circle contained in other
        if abs(radius(c1)) < abs(radius(c2))
            return loss1(c1, d) # return loss1 of smaller class (c1) and d
        else
            return loss1(c2, d) # return loss1 of smaller class (c2) and d
        end
    elseif dist == 0 && radius(c1) == radius(c2) ## circles are coincident
        return loss1(c1, d) # choose one
    else
        a = (radius(c1)^2 - radius(c2)^2 + dist^2)/(2 * dist)
        rad = sqrt(radius(c1)^2 - a^2)
        cent = centerpoint(c1) + a * (centerpoint(c2) - centerpoint(c1)) / dist
        return max(0, euclidean(cent, centerpoint(d)) + abs(rad) - abs(radius(d)) + args["margin"])

    end
end

function loss2(x::Tuple{Int64,Int64,Int64})
    return loss2(x[1], x[2], x[3])
end

function loss3(c::Int, d::Int, r::Int) # normal form 3
    return max(0, euclidean(centerpoint(d) - v(r), centerpoint(c)) + abs(radius(c)) - abs(radius(d)) + args["margin"])
end

function loss3(x::Tuple{Int64,Int64,Int64})
    return loss3(x[1], x[2], x[3])
end

function loss4(c::Int, d::Int, r::Int) # normal form 4
    return max(0, euclidean(centerpoint(c) + v(r), centerpoint(d)) + abs(radius(c)) - abs(radius(d)) + args["margin"])
end

function loss4(x::Tuple{Int64,Int64,Int64})
    return loss4(x[1], x[2], x[3])
end


# generate arrays for our training data, easier to move to GPU
nf1arr =  shuffle(collect(nf1))
nf2arr =  shuffle(collect(nf2))
nf3arr =  shuffle(collect(nf3))
nf4arr =  shuffle(collect(nf4))


#BATCHSIZE = 10
#nf1arr = Flux.chunk(nf1arr, ceil(length(nf1arr)/BATCHSIZE))
#nf2arr = Flux.chunk(nf2arr, ceil(length(nf2arr)/BATCHSIZE))
#nf3arr = Flux.chunk(nf3arr, ceil(length(nf3arr)/BATCHSIZE))
#nf4arr = Flux.chunk(nf4arr, ceil(length(nf4arr)/BATCHSIZE))

# Training now...

if args["gpu"] == true
    cvec = param(cvec) |> gpu
    rvec = param(rvec) |> gpu
else
    cvec = param(cvec)
    rvec = param(rvec)
end

opt = SGD([cvec, rvec], LR)
if (length(nf1) < 10) || (length(nf2) < 10) || (length(nf3) < 10) || (length(nf4) < 10)
    for i in 1:EPOCHS
        Flux.train!(loss1, nf1arr, opt)
        Flux.train!(loss2, nf2arr, opt)
        Flux.train!(loss3, nf3arr, opt)
        Flux.train!(loss4, nf4arr, opt)
    end
else
    TESTSIZE = 20
    test1 = collect(RandomBatches(nf1arr, TESTSIZE, 1))
    test2 = collect(RandomBatches(nf2arr, TESTSIZE, 1))
    test3 = collect(RandomBatches(nf3arr, TESTSIZE, 1))
    test4 = collect(RandomBatches(nf4arr, TESTSIZE, 1))
    
    #evalcb1 = throttle(() -> @show(loss1([1])), 5)
    evalcb1 = Flux.throttle(() -> @show(sum(loss1.(test1[1]))), 20)
    evalcb2 = Flux.throttle(() -> @show(sum(loss2.(test2[1]))), 20)
    evalcb3 = Flux.throttle(() -> @show(sum(loss3.(test3[1]))), 20)
    evalcb4 = Flux.throttle(() -> @show(sum(loss4.(test4[1]))), 20)
    
    
    for i in 1:EPOCHS
        Flux.train!(loss1, nf1arr, opt, cb=evalcb1)
        Flux.train!(loss2, nf2arr, opt, cb=evalcb2)
        Flux.train!(loss3, nf3arr, opt, cb=evalcb3)
        Flux.train!(loss4, nf4arr, opt, cb=evalcb4)
    end
end

#println("Loss is ", sum(loss1.(nf1arr)) + sum(loss2.(nf2arr)) + sum(loss3.(nf3arr)) + loss4.(nf4arr))

cvec = Flux.Tracker.data(cvec)
rvec = Flux.Tracker.data(rvec)
open(args["output"], "w") do file
    write(file, "IRI")
    for i in 1:DIM
        write(file, "\tV$i")
    end
    write(file, "\tr\n")
    for (c,ind) in classes
        if ind > 0
            write(file, c)
            vec = cvec[ind,:]
            for val in vec
                write(file,"\t$val")
            end
            write(file, "\n")
        end
    end
    for (r,ind) in relations
        if ind > 0
            write(file, r)
            vec = rvec[ind,:]
            for val in vec
                write(file,"\t$val")
            end
            write(file, "\n")
        end
    end
end
