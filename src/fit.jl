##############################################################################
##
## Fit is the only exported function
##
##############################################################################


function fit(m::SparseFactorModel, 
             f::Formula, 
             df::AbstractDataFrame, 
             vcov_method::AbstractVcovMethod = VcovSimple(); 
             method::Union(Symbol, Void) = nothing, 
             lambda::Real = 0.0, 
             subset::Union(AbstractVector{Bool}, Nothing) = nothing, 
             weight::Union(Symbol, Void) = nothing, 
             maxiter::Integer = 100000, 
             tol::Real = 1e-15, 
             save = false)

    ##############################################################################
    ##
    ## Transform DataFrame -> Matrix
    ##
    ##############################################################################
    if method == :svd
        weight == nothing || error("The svd method does not handle weights")
    end


    ## parse formula 
    rf = deepcopy(f)
    (has_absorb, absorb_formula, absorb_terms, has_iv, iv_formula, iv_terms, endo_formula, endo_terms) = decompose!(rf)
    if has_iv
        error("partial_out does not support instrumental variables")
    end
    rt = Terms(rf)
    has_regressors = allvars(rf.rhs) != [] || (rt.intercept == true && !has_absorb)

    # change default if has_regressors
    if !has_regressors
        save = true
    end
    ## create a dataframe without missing values & negative weights
    vars = allvars(rf)
    vcov_vars = allvars(vcov_method)
    absorb_vars = allvars(absorb_formula)
    factor_vars = [m.id, m.time]
    all_vars = vcat(vars, absorb_vars, factor_vars, vcov_vars)
    all_vars = unique(convert(Vector{Symbol}, all_vars))
    esample = complete_cases(df[all_vars])
    if weight != nothing
        esample &= isnaorneg(df[weight])
        all_vars = unique(vcat(all_vars, weight))
    end
    if subset != nothing
        if length(subset) != size(df, 1)
            error("df has $(size(df, 1)) rows but the subset vector has $(length(subset)) elements")
        end
        esample &= convert(BitArray, subset)
    end
    subdf = df[esample, all_vars]
    main_vars = unique(convert(Vector{Symbol}, vcat(vars, factor_vars)))
    for v in main_vars
        dropUnusedLevels!(subdf[v])
    end

    # Compute data needed for errors
    vcov_method_data = VcovMethodData(vcov_method, subdf)

    # Compute weight
    sqrtw = get_weight(subdf, weight)

    ## Compute factors, an array of AbtractFixedEffects
    if has_absorb
        fes = FixedEffect[FixedEffect(subdf, a, sqrtw) for a in absorb_terms.terms]
        # in case some FixedEffect is aFixedEffectIntercept, remove the intercept
        if any([typeof(f.interaction) <: Ones for f in fes]) 
            rt.intercept = false
        end
        pfe = FixedEffectProblem(fes)
    else
        pfe = nothing
    end

    # initialize iterations and converged
    iterations = Int[]
    converged = Bool[]

    # get two dimensions
    id = subdf[m.id]
    time = subdf[m.time]

    ##############################################################################
    ##
    ## Construict vector y and matrix X
    ##
    ##############################################################################

    # Compute demeaned X
    mf = simpleModelFrame(subdf, rt, esample)
    if has_regressors
        coef_names = coefnames(mf)
        X = ModelMatrix(mf).m
        broadcast!(*, X, X, sqrtw)
        residualize!(X, pfe, iterations, converged)
    end

    # Compute demeaned y
    py = model_response(mf)[:]
    yname = rt.eterms[1]
    if eltype(py) != Float64
        y = convert(py, Float64)
    else
        y = py
    end
    broadcast!(*, y, y, sqrtw)
    oldy = deepcopy(y)
    residualize!(y, pfe, iterations, converged)

    ##############################################################################
    ##
    ## Estimate Model on Matrix
    ##
    ##############################################################################

    # initialize factor models at 0.1
    idf = PooledFactor(id.refs, length(id.pool), m.rank)
    timef = PooledFactor(time.refs, length(time.pool), m.rank)
  

    if !has_regressors 
        if method == nothing
            method = :ar
        end
        # factor model
        (iterations, converged) = 
            fit!(Val{method}, y, idf, timef, sqrtw, maxiter = maxiter, tol = tol, lambda = lambda)
        coef = [0.0]
    else 
        if method == nothing
            method = :lm
        end
        # interactive fixed effect
        # initial b
        crossx = cholfact!(At_mul_B(X, X))
        coef =  crossx \ At_mul_B(X, y)
        # initial loadings
        fit!(Val{:ar}, y - X * coef, idf, timef, sqrtw, maxiter = 100, tol = 1e-3)
        # estimate the model
        M = crossx \ X'
        (coef, iterations, converged) = 
         fit!(Val{method}, X, M, coef, y, idf, timef, sqrtw; maxiter = maxiter, tol = tol, lambda = lambda) 
    end

    ##############################################################################
    ##
    ## Compute residuals
    ##
    ##############################################################################

    # compute residuals
    residuals = deepcopy(y)
    if has_regressors
        subtract_b!(residuals, coef, X)
    end
    for r in 1:m.rank
        subtract_factor!(residuals, sqrtw, idf, timef, r)
    end
    broadcast!(/, residuals, residuals, sqrtw)

    ##############################################################################
    ##
    ## Save factors and loadings in a dataframe
    ##
    ##############################################################################

    if !save 
        augmentdf = DataFrame()
    else
        augmentdf = DataFrame(idf, timef, esample)

        # save residuals in a dataframe
        if all(esample)
            augmentdf[:residuals] = residuals
        else
            augmentdf[:residuals] =  DataArray(Float64, size(augmentdf, 1))
            augmentdf[esample, :residuals] = residuals
        end

        # save fixed effects in a dataframe
        if has_absorb
            # residual before demeaning
            mf = simpleModelFrame(subdf, rt, esample)
            oldresiduals = model_response(mf)[:]
            if has_regressors
                oldX = ModelMatrix(mf).m
                subtract_b!(oldresiduals, coef, oldX)
            end
            for r in 1:m.rank
                subtract_factor!(oldresiduals, fill(one(Float64), length(residuals)), idf, timef, r)
            end
            b = oldresiduals - residuals
            # get fixed effect
            augmentdf = hcat(augmentdf, getfe!(pfe, b, esample))
        end
    end

    ##############################################################################
    ##
    ## Compute errors
    ##
    ##############################################################################
   
    if !has_regressors
        ess = sumabs2(residuals)
        return SparseFactorResult(esample, augmentdf, ess, iterations, converged)
    else
        # compute errors for beta coefficients 
        ## partial out Y on X over dummy_time x loadio
        newfes = getfactors(y, idf, timef, sqrtw)
        newpfe = FixedEffectProblem(newfes)
        ym = deepcopy(y)
        Xm = deepcopy(X)
        iterationsv = Int[]
        convergedv = Bool[]
        residualize!(ym, newpfe, iterationsv, convergedv)
        residualize!(Xm, newpfe, iterationsv, convergedv)

        residualsm = ym - Xm * coef
        crossxm = cholfact!(At_mul_B(Xm, Xm))

        ## compute the right degree of freedom
        df_absorb_fe = 0
        if has_absorb 
            df_absorb_fe = 0
            ## poor man adjustement of df for clustedered errors + fe: only if fe name != cluster name
            for fe in fes
                if typeof(vcov_method) == VcovCluster && in(fe.factorname, vcov_vars)
                    df_absorb_fe += 0
                else
                    df_absorb_fe += sum(fe.scale .!= zero(Float64))
                end
            end
        end
        df_absorb_factors = 0
        for fe in newfes
            df_absorb_factors += 
                (typeof(vcov_method) == VcovCluster && in(fe.factorname, vcov_vars)) ? 
                    0 : sum(fe.scale .!= zero(Float64))
        end
        df_residual = size(X, 1) - size(X, 2) - df_absorb_fe - df_absorb_factors 
        if df_residual < 0
            println("There are more parameters than degrees of freedom")
            println("No degree of freedom adjustment for factor structure")
            df_residual = size(X, 1) - size(X, 2) - df_absorb_fe 
        end

        ## estimate vcov matrix
        vcov_data = VcovData(Xm, crossxm, residualsm, df_residual)
        matrix_vcov = vcov!(vcov_method_data, vcov_data)

        # compute various r2
        nobs = size(subdf, 1)
        ess = sumabs2(residualsm)
        tss = compute_tss(ym, rt.intercept, sqrtw)
        r2_within = 1 - ess / tss 

        ess = sumabs2(residuals)
        tss = compute_tss(oldy, rt.intercept || has_absorb, sqrtw)
        r2 = 1 - ess / tss 
        r2_a = 1 - ess / tss * (nobs - rt.intercept) / df_residual 

        RegressionFactorResult(coef, matrix_vcov, esample, augmentdf, coef_names, yname, f, nobs, df_residual, r2, r2_a, r2_within, ess, sum(iterations), all(converged))
    end
end


# Symbol to formula Symbol ~ 0
function fit(m::SparseFactorModel, 
             variable::Symbol, 
             df::AbstractDataFrame, 
             vcov_method::AbstractVcovMethod = VcovSimple();
             method::Symbol = :ar, 
             lambda::Real = 0.0, 
             subset::Union(AbstractVector{Bool},Nothing) = nothing, 
             weight::Union(Symbol,Nothing) = nothing, 
             maxiter::Integer = 10000, 
             tol::Real = 1e-8, 
             save = true)
    formula = Formula(variable, 0)
    fit(m, formula, df, vcov_method, method = method,lambda = lambda,subset = subset,weight = weight,subset = subset, maxiter = maxiter,tol = tol,save = save)
end



