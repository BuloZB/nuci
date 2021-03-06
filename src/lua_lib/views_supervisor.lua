--[[
Copyright 2013, CZ.NIC z.s.p.o. (http://www.nic.cz/)

This file is part of NUCI configuration server.

NUCI is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

NUCI is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with NUCI.  If not, see <http://www.gnu.org/licenses/>.
]]

require("tableutils");
require("nutils");
require("datastore");
require("xmltree");
require("commits");
require("dumper");

-- Global state varables
supervisor = {
	plugins = {},
	tree = { subnodes = {}, plugins = {} },
	collision_tree = { subnodes = {}, plugins = {} }
};

-- Add a plugin to given path in the tree
local function register_to_tree(tree, path, plugin)
	local node = tree;
	for _, level in ipairs(path) do
		local sub = node.subnodes[level] or { plugins = {}, subnodes = {} };
		node.subnodes[level] = sub;
		node = sub;
	end
	table.insert(node.plugins, plugin);
	node.plugins = table.uniq(node.plugins);
end

--[[
Find the list of plugins at given path in the tree.
If not found, returns empty set.

Takes the '*' terminal label into account.

Frow every plugin, only its first instance in the list is preserved
(so a plugin will never be present twice).
]]
local function callbacks_find(tree, path)
	local pre_result = {};
	local node = tree;
	for _, level in ipairs(path) do
		-- If there's a .* here, add it to the result
		table.insert(pre_result, (node.subnodes["*"] or {}).plugins or {});
		node = node.subnodes[level] or { subnodes = {} };
	end
	-- Add the final node's plugins
	table.insert(pre_result, node.plugins or {});
	local result = {};
	-- Flatten the result to a single list
	for _, partial in ipairs(pre_result) do
		table.extend(result, partial);
	end
	return table.uniq(result);
end

--[[
Register a plugin. It'll be inserted into the tree for callbacks.
]]
function supervisor:register_plugin(plugin)
	table.insert(self.plugins, plugin);
	for _, path in pairs(plugin:positions()) do
		register_to_tree(self.tree, path, plugin);
	end
	for _, info in pairs(plugin:collision_handlers()) do
		register_to_tree(self.collision_tree, info.path, { priority = info.priority, plugin = plugin });
	end
end

--[[
Get list of plugins that are valid for given path.
]]
function supervisor:get_plugins(path)
	if not path then
		return self.plugins
	else
		return callbacks_find(self.tree, path);
	end
end

-- Can't use the local function syntax, due to mutual dependency with merge_data
local build_children;

--[[
Take the values and convert them to a tree (eg. compact the common beginnings
of paths), creating a table-built tree. The tree is compatible with the
xmltree library.
]]
local function merge_data(values, level)
	local level = level or 1; -- If not provided, we start from the front

	--[[
	We first divide the values by their name in path on the current level.
	We have some names for the children and we set the ones wich end here
	]]
	local children_defs = {};
	local local_defs = {};
	for _, value in ipairs(values) do
		local name = value.path[level];
		if name then
			-- Get the data gathered for the child or a new list
			local def = children_defs[name] or {};
			children_defs[name] = def;
			table.insert(def, value);
		else
			table.insert(local_defs, value);
		end
	end
	--[[
	Now we have definitions for all the children, so we handle them
	(indirectly) recursively and concatenate the results together.
	Beware that there may be multiple results from one name of child.
	]]
	local children = {};
	local child_error;
	for name, values in pairs(children_defs) do
		local children_local, err = build_children(name, values, level);
		table.extend(children, children_local);
		if err then
			child_error = true;
		end;
	end
	-- Extract the local information to something more digestible
	local seen_multival;
	local multivals = {};
	local seen_val;
	local vals = {};
	local err_val;
	for _, value in ipairs(local_defs) do
		if value.multival then
			seen_multival = true;
			table.insert(multivals, value.multival);
		else
			seen_val = true;
			if next(vals) and not value.val then
				err_val = true;
			end
			table.insert(vals, value.val);
		end
	end
	-- Check for error conditions
	if seen_val and seen_multival then -- Both single and multi value?
		err_val = true;
	end
	if seen_val then
		local prev; -- All shall be the same
		for _, val in ipairs(vals) do
			if prev and prev ~= val then
				err_val = true;
			end
			prev = val;
		end
	end
	if seen_multival then
		local prev; -- All shall be the same, but we don't care about the order
		for _, mval in ipairs(multivals) do
			if prev then
				-- Little bit of abuse, but it works.
				if not match_keysets(list2map(prev), list2map(mval)) then
					err_val = true;
				end
			end
			prev = mval;
		end
	end
	-- Build the nodes
	local function build_result(value)
		local result = { text = value };
		if next(children) then
			result.children = children;
			for _, child in ipairs(children) do
				child.parent = result;
			end
		end
		local errors = {};
		if child_error then
			table.insert(errors, 'children');
		end
		if err_val then
			table.insert(errors, 'value');
		end
		if next(errors) then
			result.errors = errors;
			result.source = values;
		end
		return result;
	end
	local result = {};
	if seen_multival then
		for _, val in ipairs(multivals[1]) do
			table.insert(result, build_result(val));
		end
	else
		table.insert(result, build_result(vals[1]));
	end
	return result;
end

build_children = function(name, values, level)
	local result = {};
	while next(values) do -- Pick a keyset, filter it out and process
		local keyset = (values[1].keys or { [level] = {} })[level] or {};
		local picked, rest = {}, {};
		local key_list = {};
		-- FIXME: Check the key sets are for the same indexes (#2697)
		-- FIXME: Choose order of the keys (#2696)
		for name, value in pairs(keyset) do
			table.insert(key_list, { name = name, text = value, key = true });
		end
		for _, value in ipairs(values) do
			if match_keysets(keyset, (value.keys or { [level] = {} })[level] or {}) then
				table.insert(picked, value);
			else
				table.insert(rest, value);
			end
		end
		values = rest;
		local generated = merge_data(picked, level + 1);
		for _, child in pairs(generated) do
			local children = {};
			-- The keys must go first
			table.extend(children, key_list);
			table.extend(children, child.children or {});
			if next(children) then
				child.children = children;
			end
		end
		table.extend(result, generated);
	end
	for _, child in pairs(result) do
		child.name = name;
	end
	return result;
end

-- For debug purposes... TODO: Remove before production
local function levelizer(level)
	local out = "";
	for i=1,level do
		out = out .. "* ";
	end

	return out;
end

--[[
Recursively go through the tree and find collisions
Return true if some collision was found, false otherwise
]]
local function handle_collisions_rec(node, path, keyset, level)
	local add_keys_into_keyset = function(ks, node)
		for _, item in pairs(node.children or {}) do
			if item.key then
				ks[item.name] = item.text;
			end
		end
	end
	-- Prepare keyset structure for this level
	if not keyset[level] and level > 0 then
		keyset[level] = {};
	end
	--Fill informations about this level
	add_keys_into_keyset(keyset[level], node);
	path[level] = node.name;
	-- Detect collision in this node
	if node.errors then
		return true, node;
	end
	-- If I have some children recurse to them.
	for _, item in pairs(node.children or {}) do
		local collision_found, broken_node = handle_collisions_rec(item, path, keyset, level+1);
		if collision_found then
			-- Collision was found, distribute it
			return collision_found, broken_node;
		end
	end
	-- Cleanup my level, nothing was found and this informations are useless
	path[level] = nil;
	keyset[level] = nil;

	return false;
end

--[[
Expected status codes are:
true - plugin solved collision - is not necessary to call anything else
false - plugin wasn't able to solve collision - call something else
nil - and error occured - report error immediately
]]
local function handle_single_collision(collision_tree, tree, node, path, keyset)
	local callbacks = callbacks_find(collision_tree, path);
	table.sort(callbacks, function (a, b) return a.priority > b.priority end);
	for _, clb in ipairs(callbacks) do
		local status, err = clb.plugin:collision(tree, node, path, keyset);
		if status == true then
			-- Problem solved
			return true;
		elseif status == false then
			-- DO NOT ERASE THIS BRANCH!!
			-- Handler doesn't know how to solve collision
			-- continue;
		else
			-- An error occured
			return status, err;
		end
	end

	return nil, "Any plugin wasn't able to solve collision.";
end

function supervisor:handle_collisions()
	local collision_found, broken_node;
	local path = {};
	local keyset = {};
	while true do
		collision_found, broken_node = handle_collisions_rec(self.data, path, keyset, 0);
		if collision_found then
			local status, err = handle_single_collision(self.collision_tree, self.data, broken_node, path, keyset);
			if not status then
				return status, err;
			end
		else
			-- All collisions were solved
			break;
		end
	end

	return true;
end

--[[
Check that the tree with data from the plugins is built. If not, build it.
]]
function supervisor:check_tree_built()
	if not self.cached then
		-- Nothing ready yet. Build the complete tree and store it.

		--[[
		Make sure the data is wiped out after the current operation.
		Both after success and failure.

		Let it happen after we (possibly) push changes to the UCI system,
		but before we commit UCI.
		]]
		commit_hook_success(function() self:invalidate_cache() end, 0);
		commit_hook_failure(function() self:invalidate_cache() end, 0);
		-- First, let each plugin dump everything and store it for now.
		local values = {};
		for _, plugin in ipairs(self:get_plugins()) do
			local pvalues, errors = plugin:get();
			if errors then
				return nil, errors;
			end
			-- We call the get() without path and keys, to get everything
			for _, value in pairs(pvalues) do
				value.from = plugin; -- Remember who provided this ‒ for debugging and tracking of differences in future
			end
			table.extend(values, pvalues);
		end
		-- Go through the values and merge them together, in preorder DFS
		self.data = merge_data(values)[1]; -- There must be exactly 1 result at the top level
		-- Index the direct sub-children, for easier lookup.
		-- We assume there's just single one of each name.
		self.index = {}
		for _, subtree in pairs(self.data.children or {}) do
			self.index[subtree.name] = subtree;
		end
		local status, err = self:handle_collisions()
		if not status then
			return status, err;
		end
		self.cached = true;
	end

	return true;
end

function supervisor:get(name, ns)
	local status, err = self:check_tree_built();
	if not status then
		return status, err;
	end
	--[[
	Extract the appropriate part of tree and convert to XML.

	First, take the part of the tree by the name, set up the namespace and
	run it through the xmltree module.
	]]
	local subtree = self.index[name] or { name = name };
	subtree.namespace = ns;
	return xmltree_dump(subtree);
end

--[[
Invalidate cache, most useful after a complete get or editconfig request.
]]
function supervisor:invalidate_cache()
	self.cached = nil;
	self.data = nil;
	self.index = nil;
end

--[[
Generate a usual datasource provider based on the supervisor and views.
Pass the yin file, the rest is extracted from it.
]]
function supervisor:generate_datasource_provider(yin_name)
	local datastore = datastore(yin_name);
	local supervisor = self;

	function datastore:get()
		local doc, err = supervisor:get(self.model_name, self.model_ns);

		if doc then
			return doc:strdump();
		else
			return nil, err;
		end
	end

	return datastore;
end
