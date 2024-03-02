function tasks_macro(forex)
    if forex.head != :for
        throw(ErrorException("Expected a for loop after `@tasks`."))
    else
        if forex.args[1].head != :(=)
            # this'll catch cases like
            # @tasks for _ ∈ 1:10, _ ∈ 1:10
            #     body
            # end
            throw(ErrorException("`@tasks` currently only supports a single threaded loop, got $(forex.args[1])"))
        end
        it = forex.args[1]
        itvar = it.args[1]
        itrng = it.args[2]
        forbody = forex.args[2]
    end

    settings = Settings()

    inits_before, inits_names = _maybe_handle_init_block!(forbody.args)
    tls_names = isnothing(inits_before) ? [] : map(x -> x.args[1], inits_before)
    
    _maybe_handle_set_block!(settings, forbody.args)

    forbody = esc(forbody)
    itrng = esc(itrng)
    itvar = esc(itvar)

    make_mapping_function = if isempty(tls_names)
        :(local function mapping_function($itvar,)
              $(forbody)
          end)

    else
        :(local mapping_function = WithTaskLocals(($(tls_names...),)) do ($(inits_names...),)
              function mapping_function_local($itvar,)
                  $(forbody)
              end
          end)
    end
    q = if !isnothing(settings.reducer)
        quote
            $make_mapping_function
            tmapreduce(mapping_function, $(settings.reducer), $(itrng); scheduler = $(settings.scheduler)) 
        end
    elseif settings.collect
        quote
            $make_mapping_function
            tmap(mapping_function, $(itrng); scheduler = $(settings.scheduler))
        end
    else
        quote
            $make_mapping_function
            tforeach(mapping_function, $(itrng); scheduler = $(settings.scheduler))
        end
    end

    # wrap everything in a let ... end block
    # and, potentially, define the `TaskLocalValue`s.
    result = :(let
    end)
    push!(result.args[2].args, q)
    if !isnothing(inits_before)
        for x in inits_before
            push!(result.args[1].args, x)
        end
    end

    result
end

Base.@kwdef mutable struct Settings
    scheduler::Expr = :(DynamicScheduler())
    reducer::Union{Expr, Symbol, Nothing} = nothing
    collect::Bool = false
end

function _sym2scheduler(s)
    if s == :dynamic
        :(DynamicScheduler())
    elseif s == :static
        :(StaticScheduler())
    elseif s == :greedy
        :(GreedyScheduler())
    else
        throw(ArgumentError("Unknown scheduler symbol."))
    end
end

function _maybe_handle_init_block!(args)
    inits_before = nothing
    init_inner = nothing
    tlsidx = findfirst(args) do arg
        arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@init")
    end
    if !isnothing(tlsidx)
        inits_before, init_inner = _unfold_init_block(args[tlsidx].args[3])
        deleteat!(args, tlsidx)
    end
    return inits_before, init_inner
end

function _unfold_init_block(ex)
    inits_before = Expr[]
    inits_names = Expr[]
    if ex.head == :(=)
        initb, init_name = _init_assign_to_exprs(ex)
        push!(inits_before, initb)
        push!(inits_names, init_name)
    elseif ex.head == :block
        tlsexprs = filter(x -> x isa Expr, ex.args) # skip LineNumberNode
        for x in tlsexprs
            initb, initn = _init_assign_to_exprs(x)
            push!(inits_before, initb)
            push!(inits_names,  initn)
        end
    else
        throw(ErrorException("Wrong usage of @init. You must either provide a typed assignment or multiple typed assignments in a `begin ... end` block."))
    end
    return inits_before, inits_names
end

function _init_assign_to_exprs(ex)
    left_ex = ex.args[1]
    if left_ex isa Symbol || left_ex.head != :(::)
        throw(ErrorException("Wrong usage of @init. Expected typed assignment, e.g. `A::Matrix{Float} = rand(2,2)`."))
    end
    tls_sym = esc(left_ex.args[1])
    tls_type = esc(left_ex.args[2])
    tls_def = esc(ex.args[2])
    @gensym tl_storage
    init_before = :($(tl_storage) = TaskLocalValue{$tls_type}(() -> $(tls_def)))
    init_name = :($(tls_sym))
    return init_before, init_name
end

function _maybe_handle_set_block!(settings, args)
    idcs = findall(args) do arg
        arg isa Expr && arg.head == :macrocall && arg.args[1] == Symbol("@set")
    end
    isnothing(idcs) && return # no set block found
    for i in idcs
        ex = args[i].args[3]
        if ex.head == :(=)
            _handle_set_single_assign!(settings, ex)
        elseif ex.head == :block
            exprs = filter(x -> x isa Expr, ex.args) # skip LineNumberNode
            _handle_set_single_assign!.(Ref(settings), exprs)
        else
            throw(ErrorException("Wrong usage of @set. You must either provide an assignment or multiple assignments in a `begin ... end` block."))
        end
    end
    deleteat!(args, idcs)
    # check incompatible settings
    if settings.collect && !isnothing(settings.reducer)
        throw(ArgumentError("Specifying both collect and reducer isn't supported."))
    end
end

function _handle_set_single_assign!(settings, ex)
    if ex.head != :(=)
        throw(ErrorException("Wrong usage of @set. Expected assignment, e.g. `scheduler = StaticScheduler()`."))
    end
    sym = ex.args[1]
    if !hasfield(Settings, sym)
        throw(ArgumentError("Unknown setting \"$(sym)\". Must be ∈ $(fieldnames(Settings))."))
    end
    def = ex.args[2]
    if sym == :collect && !(def isa Bool)
        throw(ArgumentError("Setting collect can only be true or false."))
        #TODO support specifying the OutputElementType
    end
    def = if def isa QuoteNode
        _sym2scheduler(def.value)
    elseif def isa Bool
        def
    else
        esc(def)
    end
    setfield!(settings, sym, def)
end