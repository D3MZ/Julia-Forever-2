using Test,JSON,Tachikoma,JuliaForever2,CommonMark

module ThemeNativeTests
using JSON,Tachikoma,JuliaForever2,CommonMark
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const App=Owner.App
const KeyEvent=Tachikoma.KeyEvent
const pi_style=Owner.pi_style
const menu_token_score=Owner.menu_token_score
include(joinpath(@__DIR__,"..","ext","terminal","menu_search_input.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","menu_thinking.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","theme_colors.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","theme_system.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","theme_runtime.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","menu_theme.jl"))
end
const NativeThemeTests=ThemeNativeTests

module ThemeParentRenderer
using JSON,Tachikoma,JuliaForever2,CommonMark
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const App=Owner.App
const KeyEvent=Tachikoma.KeyEvent
const MenuSearchInput=Owner.MenuSearchInput
const menu_search_spans=Owner.menu_search_spans
const menu_preference=Owner.menu_preference
const current=Ref{Any}(nothing)
pi_style(key::Symbol)=Main.NativeThemeTests.theme_style(current[],key)
include(joinpath(dirname(dirname(pathof(JuliaForever2))),"ext","terminal","menu_settings.jl"))
end

"""Serialize actual native spans, leaving normalization to an independent terminal engine."""
function theme_test_ansi(lines)
    [sprint() do io
        for span in line
            Tachikoma.write_style(io,span.style)
            print(io,span.content,"\e[0m")
        end
    end for line in lines]
end

"""Reproduce supplied terminal reports as native integers without terminal probing."""
function theme_test_environment!(catalog,environment,mode)
    colors=environment["colors"]
    rgb(value)=(Int(value["r"]),Int(value["g"]),Int(value["b"]))
    catalog.background=haskey(colors,"background") ? rgb(colors["background"]) : nothing
    catalog.foreground=haskey(colors,"foreground") ? rgb(colors["foreground"]) : nothing
    catalog.palette=haskey(colors,"palette") ? rgb.(colors["palette"]) : NTuple{3,Int}[]
    catalog.pending=get(environment,"pending",false)
    reported=get(environment,"scheme",nothing)
    catalog.appearance=NativeThemeTests.theme_detect_appearance(;background=catalog.background,foreground=catalog.foreground,
        reported=isnothing(reported) ? nothing : Symbol(reported),colorfgbg=get(environment,"colorfgbg",""))
    catalog.mode=mode=="256color" ? :indexed : :truecolor
    catalog
end

"""Compare all actual foreground/background token escapes and dim attributes."""
function theme_test_palette(actual,expected,label,failures)
    for (token,row) in expected["tokens"]
        style=NativeThemeTests.theme_token_style(actual,token)
        color=row["slot"]=="foreground" ? style.fg : style.bg
        ansi=sprint(io -> row["slot"]=="foreground" ? Tachikoma.write_fg(io,color) : Tachikoma.write_bg(io,color))
        if color isa Tachikoma.NoColor
            ansi=row["slot"]=="foreground" ? "\e[39m" : "\e[49m"
        end
        original=replace(row["ansi"],"\e[2m"=>"")
        expected_dim=occursin("\e[2m",row["ansi"])
        if ansi!=original || style.dim!=expected_dim
            push!(failures,(case=label,field="palette/$token",actual=(ansi,style.dim),expected=(original,expected_dim)))
        end
    end
    if String(actual.appearance)!=expected["appearance"]
        push!(failures,(case=label,field="appearance",actual=String(actual.appearance),expected=expected["appearance"]))
    end
end

"""Expose selection and callback state without using the original state's values as native input."""
function theme_test_state(menu,callbacks)
    items=NativeThemeTests.theme_menu_items(menu)
    encoded=[Dict{String,Any}("value"=>item.value,"label"=>item.label) for item in items]
    for (item,value) in zip(items,encoded)
        if !isempty(item.description)
            value["description"]=item.description
        end
        if hasproperty(item,:currentValue)
            value["currentValue"]=item.currentValue
        end
    end
    (submenuOpen=menu.open,mode=menu.open ? String(menu.mode) : nothing,
        singleTheme=menu.standalone || !menu.open ? nothing : menu.single,
        lightTheme=menu.standalone || !menu.open ? nothing : menu.light,
        darkTheme=menu.standalone || !menu.open ? nothing : menu.dark,
        originalThemeSetting=menu.standalone || !menu.open ? nothing : menu.original,
        settingValue=menu.standalone ? nothing : menu.runtime.committed,
        nestedChoiceOpen=menu.child!=:none,items=encoded,selectedIndex=menu.cursor-1,
        selectedValue=1<=menu.cursor<=length(items) ? items[menu.cursor].value : nothing,callbackState=deepcopy(callbacks))
end

"""Use the real existing native settings renderer after its child returns; palette binding is test-only."""
function theme_test_parent_lines(app,menu,width)
    app.menus.path=["settings"]
    app.menus.preferences["theme"]=menu.runtime.committed
    ThemeParentRenderer.current[]=menu.runtime
    lines=ThemeParentRenderer.settings_lines(app,width)
    # Original SettingsList.cursor is constructed once; only its text/value callbacks are dynamic.
    for row in lines
        if !isempty(row) && startswith(first(row).content,"→ ")
            first_span=popfirst!(row)
            pushfirst!(row,Tachikoma.Span(first_span.content[5:end],first_span.style))
            pushfirst!(row,NativeThemeTests.theme_span("→ ",menu.original_parent_theme,:accent))
        end
    end
    lines
end

@testset "Native themes: original-source runtime, transitions and rendered cells" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            oracle=joinpath(@__DIR__,"differential","pi_theme_oracle.mjs")
            provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            output=joinpath(directory,"original.json")
            run(`node $oracle $reference $provenance $output`)
            original=JSON.parsefile(output)
            @test original["provenance"]["checkedSourceFiles"]==513
            failures=[]
            fixture_root=joinpath(directory,"fixtures")
            for fixture in original["fixtures"]
                path=replace(fixture["path"],"\$FIXTURE"=>fixture_root)
                mkpath(dirname(path));write(path,fixture["content"])
            end
            for case in original["runtimeCases"]
                catalog=theme_test_environment!(NativeThemeTests.theme_catalog("";preserve_extras=false),case["environment"],case["mode"])
                @test String(catalog.appearance)==case["terminalAppearance"]
                actual=NativeThemeTests.theme_load(catalog,case["theme"])
                @test actual.ok
                theme_test_palette(actual.theme,original["palettes"][case["palette"]],case["environment"]["id"]*"/"*case["theme"]*"/"*case["mode"],failures)
            end
            for case in original["validationCases"]
                for mode in ("truecolor","256color")
                    expected=haskey(case,mode) ? case[mode] : case
                    actual=NativeThemeTests.theme_read_path(joinpath(fixture_root,"validation",case["id"]);mode=mode=="256color" ? :indexed : :truecolor)
                    if actual.ok!=expected["loaded"]
                        push!(failures,(case=case["id"],field="loaded",actual=actual.ok,expected=expected["loaded"]))
                    elseif actual.ok && haskey(case,mode)
                        theme_test_palette(actual.theme,original["palettes"][expected["palette"]],case["id"]*"/"*mode,failures)
                    end
                end
            end
            for case in original["automaticSettings"]
                parsed=NativeThemeTests.theme_auto_setting(case["input"])
                mapped=isnothing(parsed) ? nothing : Dict("lightTheme"=>parsed.light,"darkTheme"=>parsed.dark)
                @test mapped==case["parsed"]
                @test NativeThemeTests.theme_resolve_setting(case["input"],:dark)==case["resolvedDark"]
                @test NativeThemeTests.theme_resolve_setting(case["input"],:light)==case["resolvedLight"]
            end
            snapshots,expected_rows=[],[]
            for case in original["cases"]
                spec,width,id=case["fixture"],case["width"],case["id"]
                environment=first(row["environment"] for row in original["runtimeCases"] if row["environment"]["id"]==spec["environment"])
                catalog=theme_test_environment!(NativeThemeTests.theme_catalog(joinpath(fixture_root,"themes");preserve_extras=false),environment,spec["mode"])
                runtime=NativeThemeTests.ThemeRuntime(catalog;setting=spec["setting"],settings_path=joinpath(directory,"native-settings.json"))
                callbacks=Dict{String,Any}("previewRequests"=>String[],"changeRequests"=>String[],"selectRequests"=>String[],"cancelCount"=>0)
                observed=[]
                function receive(kind,setting,result)
                    if kind in (:preview,:change,:select)
                        push!(callbacks[string(kind)*"Requests"],setting)
                        push!(observed,(kind=String(kind),requested=setting,success=result.ok))
                    elseif kind==:cancel
                        callbacks["cancelCount"]+=1
                        push!(observed,(kind="cancel",))
                    end
                    nothing
                end
                menu=NativeThemeTests.theme_menu(runtime;standalone=spec["standalone"],available=spec["availableThemes"],on_event=receive)
                app=ThemeNativeTests.Owner.App(;settings_dir=mktempdir())
                app.menus.path=["settings"]
                app.menus.cursor=length(ThemeParentRenderer.settings_definitions(false))
                if !spec["standalone"]
                    for (key,value) in case["initial"]["parentSettings"]["values"]
                        app.menus.preferences[key]=value
                    end
                end
                stages=[(index=-1,event=nothing,after=case["initial"]);[(index=transition["index"],event=transition["event"],after=transition["after"]) for transition in case["transitions"]]]
                for stage in stages
                    if !isnothing(stage.event)
                        NativeThemeTests.theme_menu_input!(menu,stage.event["data"])
                    end
                    expected=stage.after
                    label=stage.index<0 ? "$id.initial" : "$id.step-$(stage.index)"
                    actual=JSON.parse(JSON.json(theme_test_state(menu,callbacks)))
                    for (field,value) in actual
                        if (menu.open || !(field in ("items","selectedIndex","selectedValue"))) && value!=expected[field]
                            push!(failures,(case="$label@$width",field=field,actual=value,expected=expected[field]))
                        end
                    end
                    theme_test_palette(runtime.active,original["palettes"][expected["palette"]],"$label@$width",failures)
                    lines=menu.open ? NativeThemeTests.theme_menu_lines(menu,width) : theme_test_parent_lines(app,menu,width)
                    push!(snapshots,(id=label,width=width,ansiLines=theme_test_ansi(lines)))
                    push!(expected_rows,(id=label,width=width,terminalAnsiLines=expected["terminalAnsiLines"]))
                end
                close(app.session)
            end
            evidence=get(ENV,"THEME_EVIDENCE_DIR",directory);mkpath(evidence)
            write(joinpath(evidence,"native.json"),JSON.json((snapshots=snapshots,)))
            write(joinpath(evidence,"reference.json"),JSON.json((snapshots=expected_rows,)))
            write(joinpath(evidence,"state-differences.json"),JSON.json((frames=length(snapshots),failures=failures)))
            cp(output,joinpath(evidence,"original-fresh.json");force=true)
            foreach(println,first(failures,min(12,length(failures))))
            @test isempty(failures)
            @test length(snapshots)==690
            comparator=joinpath(dirname(dirname(pathof(JuliaForever2))),"parity","compare_terminal_cells.mjs")
            expected_path,native_path,cells_path=(joinpath(evidence,file) for file in ("reference.json","native.json","cell-differences.json"))
            run(`node $comparator $expected_path $native_path $cells_path`)
            cells=JSON.parsefile(cells_path)
            @test cells["checked"]==690 && cells["matching"]==690
        end
    end
end

@testset "Native theme runtime real persistence, rollback and failure contracts" begin
    mktempdir() do directory
        catalog=NativeThemeTests.theme_catalog(joinpath(directory,"themes"))
        mkpath(catalog.directory)
        path=joinpath(directory,"terminal-settings.json")
        write(path,JSON.json(Dict("unrelated"=>Dict("preserve"=>true),"theme"=>"dark")))
        runtime=NativeThemeTests.theme_restore(catalog,path)
        @test runtime.active.name=="dark"
        @test runtime.committed=="dark"
        before=read(path,String)
        @test NativeThemeTests.theme_preview!(runtime,"light").ok
        @test runtime.active.name=="light" && runtime.committed=="dark"
        @test read(path,String)==before
        @test NativeThemeTests.theme_revert!(runtime).ok
        @test runtime.active.name=="dark"
        @test NativeThemeTests.theme_apply!(runtime,"light/dark").ok
        @test JSON.parsefile(path)["unrelated"]==Dict("preserve"=>true)
        @test JSON.parsefile(path)["theme"]=="light/dark"
        @test stat(path).mode & 0o777==0o600
        restored=NativeThemeTests.theme_restore(catalog,path)
        @test restored.committed=="light/dark" && restored.active.name=="dark"
        @test NativeThemeTests.theme_terminal!(restored;reported=:light).ok
        @test restored.active.name=="light"
        @test JSON.parsefile(path)["theme"]=="light/dark"
        @test NativeThemeTests.theme_terminal!(restored;background=(20,20,24),foreground=(235,235,235)).ok
        @test restored.active.name=="dark"
        NativeThemeTests.theme_terminal!(restored;foreground=(220,220,220))
        @test catalog.background==(20,20,24) && catalog.foreground==(220,220,220)
        @test !NativeThemeTests.theme_apply!(restored,"does-not-exist").ok
        @test restored.committed=="light/dark"
        @test JSON.parsefile(path)["theme"]=="light/dark"
        denied=NativeThemeTests.theme_apply!(restored,"light";persist=(path,setting)->(ok=false,reason="owner denied"))
        @test !denied.ok && denied.reason=="owner denied"
        @test restored.committed=="light/dark"
        write(path,"{malformed")
        @test !NativeThemeTests.theme_apply!(restored,"light").ok
        @test read(path,String)=="{malformed"
        @test restored.committed=="light/dark"
        @test !isempty(NativeThemeTests.theme_restore(catalog,path).last_error)
        @test !NativeThemeTests.theme_store!(directory,"light").ok
        @test !NativeThemeTests.theme_store!("","light").ok
        symlink(path,joinpath(directory,"link.json"))
        @test !NativeThemeTests.theme_store!(joinpath(directory,"link.json"),"light").ok
        @test !isempty(NativeThemeTests.theme_restore(catalog,joinpath(directory,"link.json")).last_error)
        @test all(theme->theme.name in NativeThemeTests.theme_available(catalog),Tachikoma.ALL_THEMES)
        native_before=Tachikoma.theme()
        native_choice=first(theme for theme in Tachikoma.ALL_THEMES if theme!=native_before)
        @test NativeThemeTests.theme_preview!(runtime,native_choice.name).ok
        @test Tachikoma.theme()==native_choice
        @test NativeThemeTests.theme_revert!(runtime).ok
        @test Tachikoma.theme()==native_before
        @test NativeThemeTests.theme_preview!(runtime,native_choice.name).ok
        @test NativeThemeTests.theme_preview!(runtime,"system").ok
        @test Tachikoma.theme()==native_before
        NativeThemeTests.activate_theme_runtime!(runtime)
        @test NativeThemeTests.ACTIVE_NATIVE_THEME[]===runtime
        @test Tachikoma.theme()==native_before
        @test withenv("FORCE_COLOR"=>"0") do
            !NativeThemeTests.ThemeCatalog().bold
        end
        @test withenv("FORCE_COLOR"=>"1") do
            NativeThemeTests.ThemeCatalog().bold
        end
        document=JSON.parsefile(joinpath(@__DIR__,"..","ext","terminal","theme_assets","dark.json"))
        document["name"]="live-custom"
        custom=joinpath(catalog.directory,"live-custom.json")
        write(custom,JSON.json(document))
        @test "live-custom" in NativeThemeTests.theme_available(catalog)
        @test NativeThemeTests.theme_preview!(runtime,"live-custom").ok
        document["colors"]["accent"]="#123456"
        write(custom,JSON.json(document))
        @test NativeThemeTests.theme_refresh!(runtime).ok
        @test runtime.active.colors["accent"]==Tachikoma.ColorRGB(0x12,0x34,0x56)
        write(custom,"{bad")
        @test !NativeThemeTests.theme_refresh!(runtime).ok
        @test runtime.active.name=="system" && !isempty(runtime.last_error)
        @test !("live-custom" in NativeThemeTests.theme_available(catalog))
        @test !isempty(catalog.diagnostics)
        write(path,JSON.json(Dict("theme"=>"dark")))
        closed=[]
        runtime=NativeThemeTests.theme_restore(catalog,path)
        menu=NativeThemeTests.theme_menu(runtime;available=["dark","light"],on_event=(args...)->push!(closed,args),persist=(path,setting)->(ok=false,reason="read-only"))
        NativeThemeTests.theme_menu_input!(menu,"\e[B")
        @test runtime.active.name=="light"
        @test !NativeThemeTests.theme_menu_input!(menu,"\r").ok
        @test menu.open && runtime.committed=="dark"
        @test JSON.parsefile(path)["theme"]=="dark"
        NativeThemeTests.theme_menu_input!(menu,"\e")
        @test !menu.open && runtime.active.name=="dark"
    end
end
