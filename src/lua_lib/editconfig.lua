require("nutils");

local netconf_ns = 'urn:ietf:params:netconf:base:1.0'
local yang_ns = 'urn:ietf:params:xml:ns:yang:yin:1'

-- Compare names and namespaces of two nodes
local function cmp_elemname(command_node, config_node)
	local name1, ns1 = command_node:name();
	local name2, ns2 = config_node:name();
	ns1 = ns1 or ns; -- The namespace may be missing from the command XML, as it is only snippet
	return name1 == name2 and ns1 == ns2;
end
-- Compare names, namespaces and their text
local function cmp_name_content(command_node, config_node)
	return cmp_elemname(command_node, config_node, ns, model) and command_node:text() == config_node:text();
end

function extract_keys(node, model_node)
	local key_list = find_node(model_node, function(node)
		local name, ns = node:name();
		return ns == yang_ns and name == 'key';
	end):attribute('value');
	print(key_list);
end

-- Names of valid node names in model, with empty data for future extentions
local model_names = {
	leaf={
		cmp=cmp_elemname
	},
	['leaf-list']={
		cmp=cmp_name_content
	},
	container={
		cmp=cmp_elemname,
		children=true
	},
	list={
		cmp=function(command_node, config_node, ns, model)
			-- First, it must be the same kind of thing (name and ns)
			if not cmp_elemname(command_node, config_node, ns, model) then
				return false;
			end
			local command_keys = extract_keys(command_node, model);
			local config_keys = extract_keys(config_node, model);
		end,
		children=true
	}
	-- TODO: AnyXML. What to do with that?
}

-- Find a model node corresponding to the node_name here.
-- TODO: Preprocess the model, so we can do just table lookup instead?
local function model_identify(model_dir, node_name)
	--[[
	Find a node in the current model one that is in the netconf namespace
	and it is either container, leaf, list or leaf-list that has the name
	attribute equal to node_name.
	]]
	for model in model_dir:iterate() do
		local name, ns = model:name();
		-- The corrent namespace and attribute
		if ns == yang_ns and model:attribute('name') == node_name then
			for model_name, model_opts in pairs(model_names) do
				-- Found allowed name, all done
				if name == model_name then
					return model, model_opts;
				end
			end
			-- Not a valid name. Try next node.
		end
	end
end

-- Look through the config and try to find a node corresponding to the command_node one. Consider the model.
local function config_identify(model_node, model_opts, command_node, config, ns)
	local cmp_func = model_opts.cmp;
	-- It is OK not to find, returning nothing then.
	return find_node(config, function(node)
		return cmp_func(command_node, node, ns, model_node);
	end);
end

-- Perform operation on all the children here.
local function children_perform(config, command, model, ns, defop, errop, ops)
	for command_node in command:iterate() do
		local command_name, command_ns = command_node:name();
		if command_ns == ns then
			local model_node, model_opts = model_identify(model, command_name);
			if not model_node then
				-- TODO What about errop = continue?
				return {
					msg="Unknown element",
					tag="unknown element",
					info_badelem=command_name
				};
			end
			print("Found model node " .. model_node:name() .. " for " .. command_name);
			local config_node = config_identify(model_node, model_opts, command_node, config, ns);
			-- Is there an override for the operation here?
			local operation = command_node:attribute('operation', netconf_ns) or defop;
			-- What we are asked to do (may be different from what we actually do)
			local asked_operation = operation;
			if operation == merge and not model_opts.children then
				-- Merge on leaf(like) element just replaces it.
				operation = 'replace'
			end
			if config_node then
				print("Found config node " .. config_node:name() .. " for " .. command_name);
				-- The value exists
				if operation == 'create' then
					return {
						msg="Can't create an element, such element already exists: " .. command_name,
						tag="data exists",
						info_badelem=command_name,
						info_badns=command_ns
					};
				end
				if operation == 'delete' then
					-- Normalize
					operation = 'remove';
				end
				if operation == 'merge' then
					-- We are in containerish node, that has no value, so just recurse
					operation = 'none';
				end
			else
				print("Not found corresponding node")
				-- The value does not exist in config now
				if operation == 'none' or operation == 'delete' then
					return {
						msg="Missing element in configuration: " .. command_name,
						tag="data missing",
						info_badelem=command_name,
						info_badns=command_ns
					};
				end
				if operation == 'replace' or operation == 'merge' then
					-- Normalize to something common
					operation = 'create';
				end
			end
			--[[
			Now, after normalization, we have just 5 possible operations:
			* none (recurse)
			* replace (translated to remove and create)
			* create
			* remove
			]]
			print("Performing operation " .. operation)
			local function add_op(name)
				print("Adding operation " .. name .. ' on ' .. command_node:name());
				table.insert(ops, {
					op=name,
					command_node=command_node,
					model_node=model_node,
					config_node=config_node
				});
			end
			if (operation == 'remove' or operation == 'replace') and config_node then
				add_op('remove-tree');
			end
			if operation == 'create' or operation == 'replace' then
				add_op('add-tree');
			end
			if operation == 'none' then
				-- We recurse to the rest
				add_op('enter');
				local err = children_perform(config_node, command_node, model_node, ns, asked_operation, errop, ops);
				if err then
					return err;
				end
				add_op('leave');
			end
		elseif command_ns then
			-- Skip empty namespaced stuff, that's just the whitespace between the nodes
			return {
				msg="Element in foreing namespace found",
				tag="unknown namespace",
				info_badns=command_ns
			};
		end
	end
end
--[[
Turn the <edit-config /> method into a list of trivial changes to the given
current config. The current_config, command and model are lxml2 objects. The
defop and errop are strings, specifying the default operation/error operation
on the document.

Returns either the table of modifications to perform on the config, or nil,
error. The error can be directly passed as result of the operation.

The config and command XML is supposed to be wrapped in something (since
by default there may be more elements, which wouldn't be valid XML). The
top-level element of them is ignored.
]]
function editconfig(config, command, model, ns, defop, errop)
	local config_node = config:root();
	local command_node = command:root();
	local model_node = model:root();
	local ops = {};
	err = children_perform(config_node, command_node, model_node, ns, defop, errop, ops);
	return ops, err;
end
