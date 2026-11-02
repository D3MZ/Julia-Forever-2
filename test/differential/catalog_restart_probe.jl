# Separate-process native restart probe. Synthetic metadata only; no credential or model requests.
using JuliaForever2,Tachikoma,CommonMark,JSON
const Host=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
directory,phase=ARGS
if phase=="save"
    mkpath(directory)
    registry=JuliaForever2.builtin_provider_registry()
    body=JSON.json([Dict("id"=>"restart-fixture","api"=>"openai-responses","reasoning"=>true,"contextWindow"=>64000)])
    refreshed=JuliaForever2.refresh_pi_model_catalog!(registry,:chatgpt;fetcher=Returns(body),store=JuliaForever2.FileModelStore(directory))
    refreshed.ok || error(refreshed.reason)
    write(joinpath(directory,"provider"),"chatgpt")
    write(joinpath(directory,"model-settings.json"),JSON.json(Dict("defaultModel"=>"chatgpt/restart-fixture","defaultThinking"=>"high")))
    println(JSON.json(Dict("process"=>getpid(),"phase"=>"save","nativeCatalogPersisted"=>true,"credentialOperations"=>0)))
elseif phase=="restore"
    registry=JuliaForever2.builtin_provider_registry()
    isnothing(JuliaForever2.provider_model(registry,:chatgpt,"restart-fixture")) || error("Fixture was not a fresh stock registry")
    app=Host.terminal_app(;settings_dir=directory,registry)
    provider=JuliaForever2.component(app.session.kernel,:provider)
    identity=JuliaForever2.provider_model_identity(provider)
    identity==(provider_id=:chatgpt,model_id="restart-fixture") || error("Restored model did not match")
    JuliaForever2.current_thinking_level(provider)=="high" || error("Restored thinking did not match")
    println(JSON.json(Dict("process"=>getpid(),"phase"=>"restore","provider"=>String(identity.provider_id),"model"=>identity.model_id,"thinking"=>"high","page"=>String(app.page),"credentialOperations"=>0)))
    Host.finish_shutdown!(app)
else
    error("Unknown probe phase")
end
