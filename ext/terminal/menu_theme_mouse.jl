# Original Pi mouse dispatch semantics (MIT reference attribution: theme_assets/LICENSE).
public theme_menu_mouse_dispatch!

"""Route component-local zero-based mouse coordinates through the last real theme layout."""
function theme_menu_mouse_dispatch!(menu::ThemeMenu,x::Int,y::Int;action::Symbol=:press,button::Symbol=:left,wheel_delta::Int=0)
    result = nothing
    items = theme_menu_items(menu)
    automatic = menu.mode==:automatic && menu.child==:none
    list_height = automatic ? menu.height-menu.list_row-1 : menu.list_count+(length(items)>menu.list_count ? 1 : 0)
    in_component = menu.list_row<=y<menu.list_row+list_height
    in_items = menu.list_row<=y<menu.list_row+menu.list_count
    if menu.open && !isempty(items) && in_component
        if action==:wheel && wheel_delta!=0
            previous = menu.cursor
            menu.cursor = clamp(menu.cursor+(wheel_delta<0 ? -1 : 1),1,length(items))
            if previous!=menu.cursor && !automatic
                theme_menu_selection!(menu)
            end
            result = menu.standalone ? (handled=true,render=previous!=menu.cursor) : (handled=true,focus=true,render=previous!=menu.cursor)
        elseif in_items && button==:left && action in (:press,:click)
            index = menu.list_start+y-menu.list_row
            previous = menu.cursor
            menu.cursor = action==:click ? something(menu.pressed,index) : index
            if previous!=menu.cursor && !automatic
                theme_menu_selection!(menu)
            end
            if action==:press
                menu.pressed = menu.cursor
                result = (handled=true,focus=true)
            else
                menu.pressed = nothing
                theme_menu_activate!(menu)
                result = menu.standalone ? (handled=true,) : (handled=true,focus=true)
            end
        end
    end
    result
end
