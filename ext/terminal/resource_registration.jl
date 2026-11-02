public resource_registered!, resource_registration_revision

"""Advance actual registration ownership even when an explicit replacement has identical values."""
function resource_registered!(app,kind::Symbol,name::AbstractString)
    key=(kind,String(name))
    revision=get(app.menus.resource_revisions,key,UInt(0))+UInt(1)
    app.menus.resource_revisions[key]=revision
    revision
end

"""Read per-app registration ownership without inspecting or mutating a resource file."""
resource_registration_revision(app,kind::Symbol,name::AbstractString) = get(app.menus.resource_revisions,(kind,String(name)),UInt(0))
