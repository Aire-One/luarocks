
local global_env = _G
local package, require, assert, ipairs, pairs, os, print, table, type, next, unpack =
      package, require, assert, ipairs, pairs, os, print, table, type, next, unpack

module("luarocks.loader")

local path = require("luarocks.path")
local manif_core = require("luarocks.manif_core")
local deps = require("luarocks.deps")
local cfg = require("luarocks.cfg")

context = {}

-- Contains a table when rocks trees are loaded,
-- or 'false' to indicate rocks trees failed to load.
-- 'nil' indicates rocks trees were not attempted to be loaded yet.
rocks_trees = nil

local function load_rocks_trees() 
   local any_ok = false
   local trees = {}
   for _, tree in pairs(cfg.rocks_trees) do
      local rocks_dir = path.rocks_dir(tree)
      local manifest, err = manif_core.load_local_manifest(rocks_dir)
      if manifest then
         any_ok = true
         table.insert(trees, {rocks_dir=rocks_dir, manifest=manifest})
      end
   end
   if not any_ok then
      rocks_trees = false
      return false
   end
   rocks_trees = trees
   return true
end

--- Process the dependencies of a package to determine its dependency
-- chain for loading modules.
-- @parse name string: The name of an installed rock.
-- @parse version string: The version of the rock, in string format
-- @parse manifest table: The local manifest table where this rock
-- is installed.
function add_context(name, version)
   -- assert(type(name) == "string")
   -- assert(type(version) == "string")
   -- assert(type(manifest) == "table")

   if context[name] then
      return
   end
   context[name] = version

   if not rocks_trees and not load_rocks_trees() then
      return nil
   end

   local providers = {}
   for _, tree in pairs(rocks_trees) do
      local manifest = tree.manifest

      local pkgdeps = manifest.dependencies and manifest.dependencies[name][version]
      if not pkgdeps then
         return
      end
      for _, dep in ipairs(pkgdeps) do
         local package, constraints = dep.name, dep.constraints
   
         for _, tree in pairs(rocks_trees) do
            local entries = tree.manifest.repository[package]
            if entries then
               for version, packages in pairs(entries) do
                  if (not constraints) or deps.match_constraints(deps.parse_version(version), constraints) then
                     add_context(package, version, tree.manifest)
                  end
               end
            end
         end
      end
   end
end

--- Internal sorting function.
-- @param a table: A provider table.
-- @param b table: Another provider table.
-- @return boolean: True if the version of a is greater than that of b.
local function sort_versions(a,b)
   return a.version > b.version
end

local function call_other_loaders(module, name, version, file)
   
   local actual_module = file:match(".*/(.*)%.[^.]+$")
   for i, loader in pairs(package.loaders) do
      if loader ~= luarocks_loader then
         local results = { loader(actual_module) }
         if type(results[1]) == "function" then
            return unpack(results)
         end
      end
   end
   return nil, "Failed loading module "..module.." in LuaRocks rock "..name.." "..version
end

local function pick_module(module)
   --assert(type(module) == "string")

   if not rocks_trees and not load_rocks_trees() then
      return nil
   end

   local providers = {}
   for _, tree in pairs(rocks_trees) do
      local entries = tree.manifest.modules[module]
      if entries then
         for i, entry in ipairs(entries) do
            local name, version = entry:match("^([^/]*)/(.*)$")
            local file = tree.manifest.repository[name][version][1].modules[module]
            local deploy_dir
            if file:match(cfg.lua_extension.."$") then
               deploy_dir = cfg.deploy_lua_dir
            else
               deploy_dir = cfg.deploy_bin_dir
            end
            if i == 1 then
               file = deploy_dir.."/"..file
            else
               file = path.versioned_name(deploy_dir.."/"..file, name, version)
            end
            if context[name] == version then
               return name, version, file
            end
            version = deps.parse_version(version)
            table.insert(providers, {name = name, version = version, file = file})
         end
      end
   end

   if next(providers) then
      table.sort(providers, sort_versions)
      local first = providers[1]
      return first.name, first.version.string, first.file
   end
end

--- Package loader for LuaRocks support.
-- A module is searched in installed rocks that match the
-- current LuaRocks context. If module is not part of the
-- context, or if a context has not yet been set, the module
-- in the package with the highest version is used.
-- @param module string: The module name, like in plain require().
-- @return table: The module table (typically), like in plain
-- require(). See <a href="http://www.lua.org/manual/5.1/manual.html#pdf-require">require()</a>
-- in the Lua reference manual for details.

function luarocks_loader(module)
   local name, version, file = pick_module(module)
   if not name then
      return nil, "No LuaRocks module found for "..module
   else
      add_context(name, version)
      return call_other_loaders(module, name, version, file)
   end
end

table.insert(global_env.package.loaders, 1, luarocks_loader)
