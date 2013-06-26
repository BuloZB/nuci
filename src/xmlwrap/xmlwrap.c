/*
* Copyright (C) 2012 Alvin Difuntorum <alvinpd09@gmail.com>
* Copyright (C) 2013 Robin Obůrka <robin.oburka@nic.cz>
* Copyright (C) 2013 Michal Vaner <michal.vaner@nic.cz>
*
* Permission is hereby granted, free of charge, to any person obtaining
* a copy of this software and associated documentation files (the
* "Software"), to deal in the Software without restriction, including
* without limitation the rights to use, copy, modify, merge, publish,
* distribute, sublicense, and/or sell copies of the Software, and to
* permit persons to whom the Software is furnished to do so, subject to
* the following conditions:
*
* The above copyright notice and this permission notice shall be
* included in all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include "xmlwrap.h"

#include <libxml/parser.h>
#include <libxml/tree.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdbool.h>
#include <assert.h>

#define WRAP_XMLDOC		"xmlDocPtr"
#define WRAP_XMLNODE		"xmlNodePtr"

struct xmlwrap_object {
	xmlDocPtr doc;
};

#define luaL_newlibtable(L,l)	\
  lua_createtable(L, 0, sizeof(l)/sizeof((l)[0]) - 1)

#define luaL_newlib(L,l)	(luaL_newlibtable(L,l), luaL_setfuncs(L,l,0))

// ================= BEGIN of 5.2 Features INJECTION ====================
/*
** set functions from list 'l' into table at top - 'nup'; each
** function gets the 'nup' elements at the top as upvalues.
** Returns with only the table at the stack.
*/
static void luaL_setfuncs (lua_State *L, const luaL_Reg *l, int nup) {
//It doesn't work with "static"
  luaL_checkstack(L, nup, "too many upvalues");
  for (; l->name != NULL; l++) {  /* fill the table with given functions */
	int i;
	for (i = 0; i < nup; i++)  /* copy upvalues to the top */
	  lua_pushvalue(L, -nup);
	lua_pushcclosure(L, l->func, nup);  /* closure with those upvalues */
	lua_setfield(L, -(nup + 2), l->name);
  }
  lua_pop(L, nup);  /* remove upvalues */
}

static void luaL_setmetatable (lua_State *L, const char *tname) {
  luaL_getmetatable(L, tname);
  lua_setmetatable(L, -2);
}

// ================= END of 5.2 Features INJECTION ====================



/*
 * We doesn't need it now, but it should be useful.
 */
#if 0
static void lua_stack_dump(lua_State *L, const char *func)
{
	int i;
	int top = lua_gettop(L);

	printf("%s stack: ", func);
	for (i = 1; i <= top; i++) { /* repeat for each level */
		int t = lua_type(L, i);

		switch (t) {
		case LUA_TSTRING: { /* strings */
			printf("%d:'%s'", i, lua_tostring(L, i));
			break;
			}
		case LUA_TBOOLEAN: { /* booleans */
			printf(lua_toboolean(L, i) ? "true" : "false");
			break;
			}
		case LUA_TNUMBER: { /* numbers */
			printf("%d:%g", i, lua_tonumber(L, i));
			break;
		}
		default: { /* other values */
			printf("%d:%s", i, lua_typename(L, t));
			break;
			}
		}
		printf(" "); /* put a separator */
	}

	printf("\n"); /* end the listing */
}
#endif
/*
 * Creates an xmlDocPtr document and returns the handle to lua
 */
static int mod_ReadFile(lua_State *L)
{
	int options = lua_tointeger(L, 3);
	const char *filename = luaL_checkstring(L, 1);
	const char *encoding = lua_tostring(L, 2);

	xmlDocPtr doc = NULL;
	struct xmlwrap_object *xml2 = NULL;

	doc = xmlReadFile(filename, encoding, options);
	if (!doc)
		return luaL_error(L, "Failed to open xml file: %s", filename);

	xml2 = lua_newuserdata(L, sizeof(*xml2));
	luaL_setmetatable(L, WRAP_XMLDOC);

	xml2->doc = doc;
	fprintf(stderr, "Created XML DOC from file %p\n", (void *) doc);

	return 1;
}

static int mod_ReadMemory(lua_State *L)
{
	size_t len;
	const char *memory = luaL_checklstring(L, 1, &len);

	xmlDocPtr doc = xmlReadMemory(memory, len, "<memory>", NULL, 0);
	if (!doc)
		return luaL_error(L, "Failed to read xml string");

	struct xmlwrap_object *xml2 = lua_newuserdata(L, sizeof(*xml2));
	luaL_setmetatable(L, WRAP_XMLDOC);

	xml2->doc = doc;
	fprintf(stderr, "Created XML DOC from mem %p\n", (void *) doc);

	return 1;
}

/*
 * Node handlers
 */

static int node_ChildrenNode(lua_State *L)
{
	xmlNodePtr cur = lua_touserdata(L, 1);

	if (cur && cur->xmlChildrenNode) {
		lua_pushlightuserdata(L, cur->xmlChildrenNode);
		luaL_setmetatable(L, WRAP_XMLNODE);
	} else {
		lua_pushnil(L);
	}

	return 1;
}

static int node_name(lua_State *L)
{
	xmlNodePtr cur = lua_touserdata(L, 1);

	if (cur) {
		lua_pushstring(L, (const char *) cur->name);
		/*
		 * The XML_DOCUMENT_NODE has garbage in the ns. We are probably
		 * not supposed to look in there.
		 */
		if (cur->ns && cur->type != XML_DOCUMENT_NODE) {
			lua_pushstring(L, (const char *) cur->ns->href);
			return 2;
		}
		return 1;
	} else {
		return 0;
	}
}

static int node_next(lua_State *L)
{
	xmlNodePtr cur = lua_touserdata(L, 1);

	if (cur && cur->next) {
		lua_pushlightuserdata(L, cur->next);
		luaL_setmetatable(L, WRAP_XMLNODE);
	} else {
		lua_pushnil(L);
	}

	return 1;
}

static int node_tostring(lua_State *L)
{
	xmlNodePtr cur = lua_touserdata(L, 1);

	lua_pushfstring(L, "(xmlNode@%p)", cur);

	return 1;
}

static int node_iterate_next(lua_State *L)
{
	if (lua_isnil(L, 2)) { // The first iteration
		// Copy the state
		lua_pushvalue(L, 1);
	} else {
		lua_remove(L, 1); // Drop the state and call next on the value
		node_next(L);
	}
	return 1;
}

static int node_iterate(lua_State *L)
{
	lua_pushcfunction(L, node_iterate_next); // The 'next' function
	node_ChildrenNode(L); // The 'state'
	// One implicit nil.
	return 2;
}

static int node_getProp(lua_State *L)
{
	xmlNodePtr cur = lua_touserdata(L, 1);
	const char *name = luaL_checkstring(L, 2);
	const char *ns = lua_tostring(L, 3);
	xmlChar *prop;
	if (ns) {
		prop = xmlGetNsProp(cur, (const xmlChar *) name, (const xmlChar *) ns);
	} else {
		prop = xmlGetNoNsProp(cur, (const xmlChar *) name);
	}
	lua_pushstring(L, (char *) prop);
	xmlFree(prop);
	return 1;
}

static int node_getText(lua_State *L)
{
	xmlNodePtr cur = lua_touserdata(L, 1);
	if (cur->type == XML_TEXT_NODE) {// This is directly the text node, get the content
		lua_pushstring(L, (const char *) cur->content);
		return 1;
	} else {// Scan the direct children if one of them is text. Pick the first one to be so.
		for (xmlNodePtr child = cur->children; child; child = child->next)
			if (child->type == XML_TEXT_NODE) {
				lua_pushstring(L, (const char *) child->content);
				return 1;
			}
		// No text found and run out of children.
		return 0;
	}
}

static int node_setText(lua_State *L)
{
	xmlNodePtr cur = lua_touserdata(L, 1);
	const char *text = lua_tostring(L, 2);
	if (cur->type != XML_TEXT_NODE) { // It either is a TEXT_NODE already, or we try to find one inside.
		bool found = false;
		for (xmlNodePtr child = cur->children; child; child = child->next)
			if (child->type == XML_TEXT_NODE) {
				found = true;
				cur = child;
				break;
			}
		if (!found) {
			return luaL_error(L, "Don't know how to add text to node without one");
		}
	}
	assert(cur->type == XML_TEXT_NODE);
	xmlFree(cur->content);
	cur->content = (xmlChar *) xmlMemoryStrdup(text);
	return 0;
}

static int node_parent(lua_State *L)
{
	xmlNodePtr cur = lua_touserdata(L, 1);

	if (cur && cur->parent) {
		lua_pushlightuserdata(L, cur->parent);
		luaL_setmetatable(L, WRAP_XMLNODE);
		return 1;
	}

	return 0;
}

static const luaL_Reg xmlwrap_node[] = {
	{ "first_child", node_ChildrenNode },
	{ "name", node_name },
	{ "next", node_next },
	{ "iterate", node_iterate },
	{ "attribute", node_getProp },
	{ "text", node_getText },
	{ "set_text", node_setText },
	{ "parent", node_parent },
	// { "__gc", node_gc }, # FIXME Anything to free here?
	{ "__tostring", node_tostring },
	{ NULL, NULL }
};

/*
 * Document handlers
 */

static int doc_GetRootElement(lua_State *L)
{
	xmlNodePtr cur = NULL;
	struct xmlwrap_object *xml2 = lua_touserdata(L, 1);

	cur = xmlDocGetRootElement(xml2->doc);
	if (cur) {
		lua_pushlightuserdata(L, cur);
		luaL_setmetatable(L, WRAP_XMLNODE);
	} else {
		lua_pushnil(L);
	}

	//don't do this in nuci
	//lua_stack_dump(L, __func__);

	return 1;
}

static int doc_NodeListGetString(lua_State *L)
{
	xmlChar *v;
	xmlDocPtr doc = lua_touserdata(L, 1);
	xmlDocPtr cur = lua_touserdata(L, 2);

	v = xmlNodeListGetString(doc, cur->xmlChildrenNode, 1);
	if (v) {
		lua_pushfstring(L, "%s", v);
		xmlFree(v);
	} else {
		lua_pushnil(L);
	}

	return 1;
}

static int doc_gc(lua_State *L)
{
	struct xmlwrap_object *xml2 = lua_touserdata(L, 1);
	fprintf(stderr, "GC XML document %p\n", (void *) xml2->doc);

	if (xml2->doc != NULL)
		xmlFreeDoc(xml2->doc);

	return 0;
}

static int doc_tostring(lua_State *L)
{
	struct xmlwrap_object *xml2 = lua_touserdata(L, 1);

	lua_pushfstring(L, "(xml2:xmlDoc@%p:%p)", xml2, xml2->doc);

	return 1;
}

// Creating document section

static int new_xml_doc(lua_State *L) {
	struct xmlwrap_object *xml2 = (struct xmlwrap_object *)calloc(1, sizeof(struct xmlwrap_object));
	xml2->doc = xmlNewDoc(BAD_CAST "1.0");

	lua_pushlightuserdata(L, xml2);
	luaL_setmetatable(L, WRAP_XMLDOC);

	return 1;
}

static int new_node(lua_State *L) {
	const char *name = lua_tostring(L, 1);

	if (name == NULL) return luaL_error(L, "I can't create node without its name");

	xmlNodePtr node = xmlNewNode(NULL, BAD_CAST name); //without namespace for now
	if (node == NULL) return luaL_error(L, "Error during creating node.");

	lua_pushlightuserdata(L, node);
	luaL_setmetatable(L, WRAP_XMLNODE);

	return 1;
}

static int doc_set_root_node(lua_State *L) {
	struct xmlwrap_object *xml2 = lua_touserdata(L, 1);
	xmlNodePtr node = lua_touserdata(L, 2);

	if (xml2 == NULL) return luaL_error(L, "Invalid xml document");
	if (node == NULL) return luaL_error(L, "set_root_node: Invalid node");

	xmlDocSetRootElement(xml2->doc, node);

	return 0;
}

static const luaL_Reg xmlwrap_doc[] = {
	{ "root", doc_GetRootElement },
	{ "NodeListGetString", doc_NodeListGetString },
	{ "set_root_node", doc_set_root_node },
	{ "__gc", doc_gc },
	{ "__tostring", doc_tostring },
	{ NULL, NULL }
};

/*
 * Register function in the package on top of stack.
 */
static void add_func(lua_State *L, const char *name, lua_CFunction function) {
	lua_pushcfunction(L, function);
	lua_setfield(L, -2, name);
}

/*
 * Lua libxml2 binding registration
 */

int xmlwrap_init(lua_State *L)
{
	// New table for the package
	lua_newtable(L);
	add_func(L, "read_file", mod_ReadFile);
	add_func(L, "read_memory", mod_ReadMemory);
	add_func(L, "new_xml_doc", new_xml_doc);
	add_func(L, "new_node", new_node);

	// Push the package as xmlwrap (which pops it)
	lua_setglobal(L, "xmlwrap");

	/*
	 * Register metatables
	 */

	/* Register metatable for the xmlDoc objects */

	luaL_newmetatable(L, WRAP_XMLDOC); /* create metatable to handle xmlDoc objects */
	lua_pushvalue(L, -1);               /* push metatable */
	lua_setfield(L, -2, "__index");     /* metatable.__index = metatable */
	luaL_setfuncs(L, xmlwrap_doc, 0);   /* add xmlDoc methods to the new metatable */
	lua_pop(L, 1);                      /* pop new metatable */

	/* Register metatable for the xmlNode objects */

	luaL_newmetatable(L, WRAP_XMLNODE); /* create metatable to handle xmlNode objects */
	lua_pushvalue(L, -1);               /* push metatable */
	lua_setfield(L, -2, "__index");     /* metatable.__index = metatable */
	luaL_setfuncs(L, xmlwrap_node, 0);  /* add xmlNode methods to the new metatable */
	lua_pop(L, 1);

	return 1;
}
