module Reports

import Base.StackTraces: StackFrame
import Dates: DateTime, now
import Profile

import DataStructures: DefaultDict
import FlameGraphs: flamegraph

struct FunctionPoint
    point :: LineNumberNode
    name  :: Symbol
end

struct TracePoint
    containing_function :: FunctionPoint
    point               :: LineNumberNode
    from_c              :: Bool
end

const found_source_files = Dict{Symbol, Union{Nothing, Symbol}}()

function find_source_file(file)
    res = Base.find_source_file(file)
    !isnothing(res) && isfile(res) && return res
    # try to translate build bot directory to local source
    res = replace(file, r".*?[\\/]usr[\\/]share[\\/]julia[\\/]stdlib" => joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "stdlib"))
    isfile(res) ? normpath(res) : nothing
end

TracePoint(frame::StackFrame) = begin
    file = get!(found_source_files, frame.file) do
        res = find_source_file(string(frame.file))
        isnothing(res) ? nothing : Symbol(res)
    end

    func_line = isnothing(frame.linfo) ? frame.line : frame.linfo.def.line - 1

    return TracePoint(
        FunctionPoint(LineNumberNode(Int(func_line), file), frame.func),
        LineNumberNode(Int(frame.line), file),
        frame.from_c
    )
end

mutable struct TraceCounts
    inclusive :: Int
    exclusive :: Int
end

TraceCounts() = TraceCounts(0, 0)

Base.:(==)(a::TraceCounts, b::TraceCounts) = begin
    a.inclusive == b.inclusive || return false
    a.exclusive == b.exclusive || return false
    return true
end
Base.hash(a::TraceCounts, h::UInt) = hash(a.inclusive, hash(a.exclusive, h))

mutable struct Report{Dict1, Dict2, Dict3, Dict4, Dict5, Dict6, FlameGraph}
    traces_by_point    :: Dict1
    traces_by_function :: Dict2
    traces_by_file     :: Dict3
    sorted_functions   :: Vector{FunctionPoint}
    sorted_files       :: Vector{Union{Nothing, Symbol}}
    callsites          :: Dict4
    callees            :: Dict5
    functionnames      :: Dict6
    tracecount         :: Int
    flamegraph         :: FlameGraph
    maxdepth           :: Int
    generated_on       :: DateTime
end

default4() = TraceCounts()
default0() = 0
default1() = DefaultDict{TracePoint, TraceCounts}(default4)
default2() = DefaultDict{FunctionPoint, Int}(default0)
default3() = Symbol("#error: no name#")

Report(flamegraph, generated_on) = Report(
    DefaultDict{LineNumberNode, TraceCounts}(TraceCounts),
    DefaultDict{FunctionPoint, TraceCounts}(TraceCounts),
    DefaultDict{Union{Nothing, Symbol}, TraceCounts}(TraceCounts),
    Vector{FunctionPoint}(),
    Vector{Union{Nothing, Symbol}}(),
    DefaultDict{LineNumberNode, DefaultDict{TracePoint, TraceCounts, typeof(default4)}}(default1),
    DefaultDict{LineNumberNode, DefaultDict{FunctionPoint, Int, typeof(default0)}}(default2),
    DefaultDict{LineNumberNode, Symbol}(default3),
    0,
    flamegraph,
    0,
    generated_on,
)

# TODO: Handle and use metadata (threadid, taskid etc.) rather than always remove it
@static if isdefined(Profile, :has_meta)
    _strip_data(data) = Profile.has_meta(data) ? Profile.strip_meta(data) : copy(data)
    const DUMMY_SEPARATOR = UInt64[1, 1, 1, 1, 0, 0]
else
    _strip_data(data) = copy(data)
    const DUMMY_SEPARATOR = UInt64[0, 0]
end

Report(data::Vector{<:Unsigned}, litrace::Dict{<:Unsigned, Vector{StackFrame}}, from_c, generated_on) = begin
    # point different lines of the same function to the same stack frame --
    # we show line-by-line info in the source files, not in the flame graph.
    seenfunctions = Dict{FunctionPoint, StackFrame}()
    function_representative(sf) = get!(seenfunctions, TracePoint(sf).containing_function, sf)
    merged_litrace = Dict(ix => map(function_representative, sfs) for (ix, sfs) in pairs(litrace))

    # 32-bit support: it seems Profile is a bit undecided about whether `data`
    # is a Vector{UInt} or a Vector{UInt64}. flamegraph calls methods where
    # it _has_ to be UInt64 even on 32 bits platforms
    report = Report(flamegraph(UInt64.(data), lidict=merged_litrace, C=from_c), generated_on)

    data = _strip_data(data)
    data, litrace = Profile.flatten(data, litrace)

    lastwaszero = true
    trace = StackFrame[]
    for d in data
        if d == 0
            if !lastwaszero
                push!(report, trace)
                empty!(trace)
            end
            lastwaszero = true
            continue
        end
        frame = litrace[d]
        if !frame.from_c || from_c
            push!(trace, frame)
            lastwaszero = false
        end
    end

    return report
end

Base.push!(r::Report, trace::Vector{StackFrame}) = begin
    trace = TracePoint.(trace)
    for pt in trace
        r.traces_by_point[pt.point].inclusive += 1
        r.traces_by_function[pt.containing_function].inclusive += 1
        r.traces_by_file[pt.point.file].inclusive += 1

        r.functionnames[pt.containing_function.point] = pt.containing_function.name
    end

    length(trace) > 0 && let pt = trace[1]
        r.traces_by_point[pt.point].exclusive += 1
        r.traces_by_function[pt.containing_function].exclusive += 1
        r.traces_by_file[pt.point.file].exclusive += 1
    end

    for (callee, caller) in @views zip(trace[1:end-1], trace[2:end])
        callee = callee.containing_function

        r.callsites[callee.point][caller].inclusive += 1
        r.callees[caller.point][callee] += 1
    end

    length(trace) > 1 && let (callee, caller) = (trace[1], trace[2])
        callee = callee.containing_function

        r.callsites[callee.point][caller].exclusive += 1
    end

    r.tracecount += 1
    # add 1 to the trace length because flamegraph() adds a dummy node
    r.maxdepth = max(r.maxdepth, length(trace) + 1)

    return r
end

Base.sort!(r::Report) = begin
    r.sorted_functions = collect(keys(r.traces_by_function))
    sort!(r.sorted_functions, by=fn -> (r.traces_by_function[fn].exclusive, fn.name), rev=true)

    r.sorted_files = collect(keys(r.traces_by_file))
    sort!(r.sorted_files, by=file -> (r.traces_by_file[file].exclusive, something(file, :var"")), rev=true)

    return r
end


end # module
