package lua;
import "core:strings";
import "core:os";
import "core:fmt";
import "core:time";
import "core:c";

GameVar :: union {
	f32,
	string
}


LuaScript :: struct {
	path: string,
	lastChecked: u64,
	chunkRef:i64 
}

VarInfo :: struct {
	vars: map[string]GameVar,
	file: string,
	lastChecked: u64
}

LuaInstance :: struct {
	state: ^lua_State,
}

LuaRef :: c.int;

LuaTable :: struct {
	ref: LuaRef
}

init :: proc () -> ^LuaInstance {
	state := luaL_newstate();
	luaL_openlibs(state);


	instance := new(LuaInstance);

	instance.state = state;

	return instance;
}

close :: proc(instance: ^LuaInstance) {
	lua_close(instance.state);

	free(instance);
}

startTableIter :: proc(lua: ^LuaInstance){
	lua_pushnil(lua.state);
}
endTableIter :: proc(lua: ^LuaInstance){
	lua_pop(lua.state, 1);
}
tableNext :: proc(lua: ^LuaInstance) -> bool{
	result := lua_next(lua.state, -2);

	return result != 0;
}
tableNextLoop :: proc(lua: ^LuaInstance) {
	lua_pop(lua.state, 1);
}

loadVarFile :: proc(lua: ^LuaInstance, file: string) -> VarInfo {
	vars := make(map[string]GameVar, 20);

	do_file(lua, file);

	startTableIter(lua);
	defer endTableIter(lua);
	for tableNext(lua) {
		defer tableNextLoop(lua);
		type := lua_type(lua.state, -1);
		key := lua_tostring(lua.state, -2);
		switch type {
			case LUA_TSTRING: {
				vars[key] = lua_tostring(lua.state, -1);
			}
			case LUA_TNUMBER: {
				vars[key] = cast(f32)lua_tonumber(lua.state, -1);
			}
			case: {
				//Don't care
			}
		}


	}

	result := VarInfo{vars=vars, file=file,lastChecked=cast(u64)time.now()._nsec};

	return result;
}
getLastModified :: proc(path: string) -> (i64, bool){
	if stat, ok := os.stat(path, context.temp_allocator); ok != 0{
		return stat.modification_time._nsec, ok != 0;
	} else {
		return 0, false;
	}
}

checkVars :: proc(lua: ^LuaInstance, info: VarInfo) -> bool {
	seconds, ok := getLastModified(info.file);
	return ok && cast(u64)seconds * 1e9 > info.lastChecked;
}

loadScript :: proc(lua: ^LuaInstance, path : string) -> LuaScript{
	instance : LuaScript = {};
	instance.path = path;
	instance.lastChecked = cast(u64)time.now()._nsec;
	luaL_loadfile(lua.state, strings.clone_to_cstring(path));
	instance.chunkRef = cast(i64)luaL_ref(lua.state, LUA_REGISTRYINDEX);
	return instance;
}

cleanupScript :: proc(lua: ^LuaInstance) {
	if lua.state != nil{
		lua_close(lua.state);
	}
	free(lua);
}

LuaTableIterator :: struct {
	size: int,
	data: ^LuaInstance,
	index: int
}

start_iterate_table :: proc(lua: ^LuaInstance) -> LuaTableIterator {
	lua_pushnil(lua.state);
	return {
		size= 0,
		data= lua,
		index= 0
	};
}

setup_next_loop :: proc(lua: ^LuaTableIterator) {
	lua_pop(lua.data.state, 1);
}
@(deferred_in=setup_next_loop)
iterate_lua_table :: proc(it: ^LuaTableIterator) -> (val: int, idx: int, cond: bool) {
	val = 0;
	cond = lua_next(it.data.state, -2) != 0;
	idx = it.index;
	it.index += 1;

	// loop is over pop that stack!
	if !cond {
		lua_pop(it.data.state, 1);
	}
	return;
}

getTableRegistry :: proc(lua: ^LuaInstance, table: LuaTable) {
	lua_rawgeti(lua.state, LUA_REGISTRYINDEX, i64(table.ref));
}

setTableString :: proc(lua: ^LuaInstance, table: LuaTable, key: string, str: string) {
	getTableRegistry(lua, table);
	push_string(lua, key);
	push_string(lua, str);

	lua_rawset(lua.state, -3);

	lua_pop(lua.state, 1);
}

setTableBool :: proc(lua: ^LuaInstance, table: LuaTable, key: string, value: bool) {
	getTableRegistry(lua, table);
	push_string(lua, key);
	lua_pushboolean(lua.state, value);

	lua_rawset(lua.state, -3);
	lua_pop(lua.state, 1);
}

setTableInteger :: proc(lua: ^LuaInstance, table: LuaTable, key: string, auto_cast value: i64) {
	getTableRegistry(lua, table);
	push_string(lua, key);
	lua_pushinteger(lua.state, value);

	lua_rawset(lua.state, -3);

	lua_pop(lua.state, 1);
}

pushTableString :: proc(lua: ^LuaInstance, table: LuaTable, str: string) {
	getTableRegistry(lua, table);
	len := lua_rawlen(lua.state, -1);

	push_string(lua, str);

	lua_rawseti(lua.state, -2, i64(len) + 1);

	lua_pop(lua.state, 1);
}
pushTableTable :: proc(lua: ^LuaInstance, table: LuaTable, child: LuaTable) {
	lua_rawgeti(lua.state, LUA_REGISTRYINDEX, i64(table.ref));

	len := lua_rawlen(lua.state, -1);

	lua_rawgeti(lua.state, LUA_REGISTRYINDEX, i64(child.ref));

	lua_rawseti(lua.state, -2, i64(len) + 1);

	lua_pop(lua.state, 1);
}

pushTableInt :: proc(lua: ^LuaInstance, table: LuaTable, auto_cast value: i64) {
	getTableRegistry(lua, table);
	len := lua_rawlen(lua.state, -1);

	lua_pushinteger(lua.state, value);
	lua_rawseti(lua.state, -2, i64(len) + 1);

	lua_pop(lua.state, 1);
}

deleteTable :: proc(lua: ^LuaInstance, table: LuaTable) {
	luaL_unref(lua.state, LUA_REGISTRYINDEX, table.ref);
}

setTableTable :: proc(lua: ^LuaInstance, table: LuaTable, key: string, child: LuaTable) {
	getTableRegistry(lua, table);
	push_string(lua, key);
	getTableRegistry(lua, child);
	lua_settable(lua.state, -3);

	lua_pop(lua.state, 1);
}

setTable :: proc {setTableString, setTableTable, setTableInteger, setTableBool};
pushTable :: proc{pushTableString, pushTableTable, pushTableInt};


push_string :: proc (lua: ^LuaInstance, str: string) {
	cstr : cstring = strings.clone_to_cstring(str, context.temp_allocator);
	lua_pushstring(lua.state, cstr);
}
getTableIntValidated :: proc(lua: ^LuaInstance, key: string) -> (int, bool) {
	cstr : cstring = strings.clone_to_cstring(key);
	defer delete(cstr);
	lua_pushstring(lua.state, cstr);
	lua_gettable(lua.state, -2);
	defer lua_pop(lua.state, 1);
	type := lua_type(lua.state, -1);
	return int(lua_tointeger(lua.state, -1)), type != LUA_TNIL;
}

tableHasKey :: proc(lua: ^LuaInstance, key: string) -> bool {
	cstr : cstring = strings.clone_to_cstring(key);
	defer delete(cstr);
	lua_pushstring(lua.state, cstr);
	lua_gettable(lua.state, -2);
	defer lua_pop(lua.state, 1);
	type := lua_type(lua.state, -1);

	return type != LUA_TNIL;
}

getTableBoolValidated :: proc(lua: ^LuaInstance, key: string) -> (value: bool, ok: bool) {
	push_string(lua, key);
	lua_gettable(lua.state, -2);
	defer lua_pop(lua.state, 1);
	type := lua_type(lua.state, -1);
	value = lua_toboolean(lua.state, -1);
	ok = type != LUA_TNIL;
	return;
}

getTableIntOrDefault :: proc(lua: ^LuaInstance, key: string, def: int) -> int {
	val, ok := getTableIntValidated(lua, key);

	if(!ok){
		return def;
	} else {
		return val;
	}
}

getTableBoolOrDefault :: proc(lua: ^LuaInstance, key: string, def: bool) -> bool {
	val, ok := getTableBoolValidated(lua, key);

	if !ok {
		return def;
	}

	return val;
}

getTableOrDefault :: proc {getTableIntOrDefault, getTableBoolOrDefault, getTableStringOrDefault};

getTableInt :: proc (lua: ^LuaInstance, key: string) -> int {
	val, _ := getTableIntValidated(lua, key);

	return val;
}
getTableFloat :: proc (lua: ^LuaInstance, key:string) -> f32 {
	return f32(getTableInt(lua, key));
}

getInt :: proc (lua: ^LuaInstance) -> int {
	return 0;
}

getTableStringOrDefault :: proc (lua: ^LuaInstance, key: string, defaultValue: string) -> (string) {
	if val, ok := getTableStringValidated(lua, key); ok {
		return val;
	} else {
		return defaultValue;
	}
} 

getTableStringValidated :: proc (lua: ^LuaInstance, key: string) -> (value: string, ok: bool) {
	push_string(lua, key);
	lua_gettable(lua.state, -2);
	defer lua_pop(lua.state, 1);
	type := lua_type(lua.state, -1);
	value = lua_tostring(lua.state, -1);
	ok = type != LUA_TNIL;
	return;

}

getTableString :: proc (lua: ^LuaInstance, key: string) -> string {
	return getTableStringOrDefault(lua, key, "");
}

loadTable :: proc (lua: ^LuaInstance, key: string) {
	str : cstring = strings.clone_to_cstring(key);
	defer delete(str);
	lua_pushstring(lua.state, str);
	lua_gettable(lua.state, -2);
}
unloadTable :: proc(lua: ^LuaInstance) {
	lua_pop(lua.state, 1);
}

createTable :: proc(lua: ^LuaInstance) -> LuaTable{
	lua_newtable(lua.state);

	ref := luaL_ref(lua.state, LUA_REGISTRYINDEX);

	return {
		ref=ref
	};

}

tableForeach :: proc(lua: ^LuaInstance, data: $R, callback: proc(^LuaInstance, $T)) {
	lua_pushnil(lua.state);
	defer lua_pop(lua.state, 1);
	for lua_next(lua.state, -2) != 0 {
		defer lua_pop(lua.state, 1);
		callback(lua, data);
	}
}

do_file :: proc(lua: ^LuaInstance, path: string) -> bool{
	str : cstring = strings.clone_to_cstring(path);

	defer delete(str);
	return luaL_dofile(lua.state, str) == 0;

}

doString :: proc(lua: ^LuaInstance, script: string) -> bool {
	str: cstring = strings.clone_to_cstring(script);

	defer delete(str);

	return luaL_dostring(lua.state, str) == 0;
} 

to_string :: proc(lua: ^LuaInstance, index:= -1) -> string {
	return lua_tostring(lua.state, index);
}

getGlobal :: proc(lua: ^LuaInstance, name: string) -> int {
	cstr := strings.clone_to_cstring(name, context.temp_allocator);
	type := lua_getglobal(lua.state, cstr);

	return type;
}
luaFunctionExists :: proc(lua: ^LuaInstance, name: string) -> bool {
	type := getGlobal(lua, name);
	lua_pop(lua.state, 1);

	return type == LUA_TFUNCTION;
}
genId :: proc () -> int {
	@static id := 0;

	id += 1;

	return id;
}

hasScriptChanged :: proc(lastUpdated: u64, path: string) -> bool {
	seconds, ok := getLastModified(path);
	return ok && cast(u64) seconds * 1e9 > lastUpdated;
}


dump_stack :: proc(lua: ^LuaInstance) {
	i := lua_gettop(lua.state);
          fmt.println(" ----------------  Stack Dump ----------------" );
          for i > 0 {
						t := lua_type(lua.state, i);
            switch (t) {
              case LUA_TSTRING:
                fmt.println(i, lua_tostring(lua.state, i));
              case LUA_TBOOLEAN:
                fmt.println(i,lua_toboolean(lua.state, i));
              case LUA_TNUMBER:
                fmt.println(i, lua_tonumber(lua.state, i));
             	case: 
						 		fmt.println(i, lua_typename(lua.state, t));            
							}
           i -= 1;
          }
         fmt.println("--------------- Stack Dump Finished ---------------" );
}

/*
for lua_next(lua.state, -2) !=0 {
	lua_pushnil(lua.state);
	defer height +=1;
	width :=0;
	for lua_next(lua.state, -2) != 0 {
		defer width += 1;
		mapvalue := lua_tointeger(lua.state, -1);
		append(&gamemap.data[height], mapvalue);
		lua_pop(lua.state, 1);
	}
	lua_pop(lua.state, 1);
}
*/





