local u = require "sql.utils"
local json = require "sql.json"
local tinsert = table.insert
local tconcat = table.concat
local a = require "sql.assert"
local M = {}

---@brief [[
---Internal functions for parsing sql statement from lua table.
---methods = { select, update, delete, insert, create, alter, drop }
---accepts tbl name and options.
---options = {join, keys, values, set, where, select}
---hopfully returning valid sql statement :D
---@brief ]]
---@tag parser.lua

---handle sqlite datatype interop
M.sqlvalue = function(v)
  return type(v) == "boolean" and (v == true and 1 or 0) or (v == nil and "null" or v)
end

M.luavalue = function(v, schema_type)
  if schema_type == "luatable" or schema_type == "json" then
    return json.decode(v)
  elseif schema_type == "boolean" then
    return v == 0 and false or true
  end

  return v
end

---string.format specifier based on value type
---@param v any: the value
---@param nonbind boolean: whether to return the specifier or just return the value.
---@return string
local specifier = function(v, nonbind)
  local type = type(v)
  if type == "number" then
    local _, b = math.modf(v)
    return b == 0 and "%d" or "%f"
  elseif type == "string" and not nonbind then
    return v:find "'" and [["%s"]] or "'%s'"
  elseif nonbind then
    return v
  else
    return ""
  end
end

local bind = function(o)
  o = o or {}
  o.s = o.s or ", "
  if not o.kv then
    o.v = o.v ~= nil and M.sqlvalue(o.v) or "?"
    return ("%s = " .. specifier(o.v)):format(o.k, o.v)
  else
    local res = {}
    for k, v in u.opairs(o.kv) do
      k = o.k ~= nil and o.k or k
      v = M.sqlvalue(v)
      v = o.nonbind and ":" .. k or v
      tinsert(res, string.format("%s" .. (o.nonbind and nil or " = ") .. specifier(v, o.nonbind), k, v))
    end
    return tconcat(res, o.s)
  end
end

---format glob pattern as part of where clause
local pcontains = function(defs)
  if not defs then
    return {}
  end
  local items = {}
  for k, v in u.opairs(defs) do
    local head = "%s glob " .. specifier(k)

    if type(v) == "table" then
      local val = u.map(v, function(_v)
        return head:format(k, M.sqlvalue(_v))
      end)
      tinsert(items, tconcat(val, " or "))
    else
      tinsert(items, head:format(k, v))
    end
  end

  return tconcat(items, " ")
end

---Format values part of sql statement
---@params defs table: key/value pairs defining sqlite table keys.
---@params defs kv: whether to bind by named keys.
local pkeys = function(defs, kv)
  kv = kv == nil and true or kv

  if not defs or not kv then
    return {}
  end

  defs = u.is_nested(defs) and defs[1] or defs

  local keys = {}
  for k, _ in u.opairs(defs) do
    tinsert(keys, k)
  end

  return ("(%s)"):format(tconcat(keys, ", "))
end

---Format values part of sql statement, usually used with select method.
---@params defs table: key/value pairs defining sqlite table keys.
---@params defs kv: whether to bind by named keys.
local pvalues = function(defs, kv)
  kv = kv == nil and true or kv -- TODO: check if defs is key value pairs instead
  if not defs or not kv then
    return {}
  end

  defs = u.is_nested(defs) and defs[1] or defs

  local keys = {}
  for k, v in u.opairs(defs) do
    if type(v) == "string" and v:match "%a+%(.+%)" then
      tinsert(keys, v)
    else
      tinsert(keys, ":" .. k)
    end
  end

  return ("values(%s)"):format(tconcat(keys, ", "))
end

---Format where part of a sql statement.
---@params defs table: key/value pairs defining sqlite table keys.
---@params name string: the name of the sqlite table
---@params join table: used as boolean, controling whether to use name.key or just key.
local pwhere = function(defs, name, join, contains)
  if not defs and not contains then
    return {}
  end

  local where = {}
  if defs then
    for k, v in u.opairs(defs) do
      k = join and name .. "." .. k or k

      if type(v) ~= "table" then
        tinsert(where, bind { v = v, k = k, s = " and " })
      else
        tinsert(where, "(" .. bind { kv = v, k = k, s = " or " } .. ")")
      end
    end
  end

  if contains then
    tinsert(where, pcontains(contains))
  end

  return ("where %s"):format(tconcat(where, " and "))
end

local plimit = function(defs)
  if not defs then
    return {}
  end

  local type = type(defs)
  local istbl = (type == "table" and defs[2])
  local offset = "limit %s offset %s"
  local limit = "limit %s"

  return istbl and offset:format(defs[1], defs[2]) or limit:format(type == "number" and defs or defs[1])
end

---Format set part of sql statement, usually used with update method.
---@params defs table: key/value pairs defining sqlite table keys.
local pset = function(defs)
  if not defs then
    return {}
  end

  return "set " .. bind { kv = defs, nonbind = true }
end

---Format join part of a sql statement.
---@params defs table: key/value pairs defining sqlite table keys.
---@params name string: the name of the sqlite table
local pjoin = function(defs, name)
  if not defs or not name then
    return {}
  end
  local target

  local on = (function()
    for k, v in pairs(defs) do
      if k ~= name then
        target = k
        return ("%s.%s ="):format(k, v)
      end
    end
  end)()

  local select = (function()
    for k, v in pairs(defs) do
      if k == name then
        return ("%s.%s"):format(k, v)
      end
    end
  end)()

  return ("inner join %s on %s %s"):format(target, on, select)
end

local porder_by = function(defs)
  -- TODO: what if nulls? should append "nulls last"
  if not defs then
    return {}
  end

  local fmt = "%s %s"
  local items = {}

  for v, k in u.opairs(defs) do
    if type(k) == "table" then
      for _, _k in u.opairs(k) do
        tinsert(items, fmt:format(_k, v))
      end
    else
      tinsert(items, fmt:format(k, v))
    end
  end

  return ("order by %s"):format(tconcat(items, ", "))
end

local partial = function(method, tbl, opts)
  opts = opts or {}
  return tconcat(
    u.flatten {
      method,
      pkeys(opts.values),
      pvalues(opts.values, opts.named),
      pset(opts.set),
      pwhere(opts.where, tbl, opts.join, opts.contains),
      porder_by(opts.order_by),
      plimit(opts.limit),
    },
    " "
  )
end

---Parse select statement to extracts data from a database
---@param tbl string: table name
---@param opts table: lists of options: valid{ select, join, order_by, limit, where }
---@return string: the select sql statement.
M.select = function(tbl, opts)
  opts = opts or {}
  local cmd = opts.unique and "select distinct %s" or "select %s"
  local t = type(opts.select)
  local select = t == "string" and opts.select or (t == "table" and tconcat(opts.select, ", ") or "*")
  local stmt = (cmd .. " from %s"):format(select, tbl)
  local method = opts.join and stmt .. " " .. pjoin(opts.join, tbl) or stmt
  return partial(method, tbl, opts)
end

---Parse select statement to update data in the database
---@param tbl string: table name
---@param opts table: lists of options: valid{ set, where }
---@return string: the update sql statement.
M.update = function(tbl, opts)
  local method = ("update %s"):format(tbl)
  return partial(method, tbl, opts)
end

---Parse insert statement to insert data into a database
---@param tbl string: table name
---@param opts table: lists of options: valid{ where }
---@return string: the insert sql statement.
M.insert = function(tbl, opts)
  local method = ("insert into %s"):format(tbl)
  return partial(method, tbl, opts)
end

---Parse delete statement to deletes data from a database
---@param tbl string: table name
---@param opts table: lists of options: valid{ where }
---@return string: the delete sql statement.
M.delete = function(tbl, opts)
  opts = opts or {}
  local method = ("delete from %s"):format(tbl)
  local where = pwhere(opts.where)
  return type(where) == "string" and method .. " " .. where or method
end

local format_action = function(value, update)
  local stmt = update and "on update" or "on delete"
  local preappend = (value:match "default" or value:match "null") and " set " or " "

  return stmt .. preappend .. value
end

---Parse table create statement
---@param tbl string: table name
---@param defs table: keys and type pairs
---@return string: the create sql statement.
M.create = function(tbl, defs)
  if not defs then
    return
  end
  local items = {}

  tbl = defs.ensure and "if not exists " .. tbl or tbl
  defs.ensure = nil

  for k, v in u.opairs(defs) do
    if type(v) == "boolean" then
      tinsert(items, k .. " integer not null primary key")
    elseif type(v) ~= "table" then
      tinsert(items, string.format("%s %s", k, v))
    else
      local _
      _ = u.if_nil(v.type, nil) and tinsert(v, v.type)
      _ = u.if_nil(v.unique, false) and tinsert(v, "unique")
      _ = u.if_nil(v.nullable, nil) == false and tinsert(v, "not null")
      _ = u.if_nil(v.pk, nil) and tinsert(v, "primary key")
      _ = u.if_nil(v.default, nil) and tinsert(v, "default " .. v.default)
      _ = u.if_nil(v.reference, nil) and tinsert(v, ("references %s"):format(v.reference:gsub("%.", "(") .. ")"))
      _ = u.if_nil(v.on_update, nil) and tinsert(v, format_action(v.on_update, true))
      _ = u.if_nil(v.on_delete, nil) and tinsert(v, format_action(v.on_delete))

      tinsert(items, ("%s %s"):format(k, tconcat(v, " ")))
    end
  end

  return ("create table %s(%s)"):format(tbl, tconcat(items, ", "))
end

---Parse table drop statement
---@param tbl string: table name
---@return string: the drop sql statement.
M.drop = function(tbl)
  return "drop table " .. tbl
end

---Preporcess data insert to sql db.
---for now it's mainly used to for parsing lua tables and boolean values.
---It throws when a schema key is required and doesn't exists.
---@param rows tinserted row.
---@param schema table tbl schema with extra info
---@return table pre processed rows
M.pre_insert = function(rows, schema)
  rows = u.is_nested(rows) and rows or { rows }
  for _, row in ipairs(rows) do
    u.foreach(schema.req, function(k)
      a.missing_req_key(row[k], k)
    end)
    u.foreach(row, function(k, v)
      local is_json = schema.types[k] == "luatable" or schema.types[k] == "json"
      row[k] = is_json and json.encode(v) or M.sqlvalue(v)
    end)
  end
  return rows
end

---Postprocess data queried from a sql db. for now it is mainly used
---to for parsing json values to lua table.
---@param rows tinserted row.
---@param schema table tbl schema
---@return table pre processed rows
---@TODO support boolean values.
M.post_select = function(rows, types)
  local is_nested = u.is_nested(rows)
  rows = is_nested and rows or { rows }

  for _, row in ipairs(rows) do
    for k, v in pairs(row) do
      row[k] = M.luavalue(v, types[k])
    end
  end

  return is_nested and rows or rows[1]
end

return M
