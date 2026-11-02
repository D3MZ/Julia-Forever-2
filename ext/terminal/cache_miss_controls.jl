"""Show large observed cache losses without presenting estimated prices as a bill."""
function cache_miss_notice_rows(miss::JuliaForever2.SessionCacheMiss,width::Int)
    rows=SessionDisplayRows()
    cost=miss.estimated_cost
    if miss.tokens>=20_000 || !isnothing(cost)&&cost>=0.1
        label=miss.model_changed ? "Cache miss after model switch" :
            !isnothing(miss.idle_ms)&&miss.idle_ms>=300_000 ? "Cache miss after $(round(Int,miss.idle_ms/60_000))m idle" : "Cache miss"
        amount=string(miss.tokens)
        suffix=isnothing(cost) ? " (cost unavailable)" : cost>=0.01 ? " (~\$$(round(cost;digits=2)) estimated)" : ""
        text=label*": "*amount*" prompt tokens not read from cache"*suffix
        push!(rows,session_display_blank(width))
        append!(rows,startup_text_lines(startup_rich(text,session_display_style(:warning)),width;padding=1))
    end
    rows
end
cache_miss_notice_rows(::Nothing,width::Int)=SessionDisplayRows()

function cache_miss_after_record_rows(app::App,id::String,anchor,width::Int,misses;projection=interrupted_fallback_projection(app),on_component=nothing)
    rows=frontend_after_record_rows(app,id,anchor,width;projection,on_component)
    append!(rows,cache_miss_notice_rows(get(misses,anchor,nothing),width))
    rows
end
