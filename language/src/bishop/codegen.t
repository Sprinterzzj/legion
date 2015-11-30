-- Copyright 2015 Stanford University, NVIDIA Corporation
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- Bishop Code Generation

local ast = require("bishop/ast")
local log = require("bishop/log")
local std = require("bishop/std")

local c = terralib.includecstring [[
#include "legion_c.h"
#include "bishop_c.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
]]

local codegen = {}

local property_setters = {
  task = {
    target = {}
  },
  region = {
    target = {}
  }
}

function property_setters:register_setter(rule_type, field, arg_type, setter)
  self[rule_type][field][arg_type] = setter
end

function property_setters:find_setter(rule_type, node)
  local setter_info = self[rule_type][node.field][node.value.expr_type]
  if not setter_info then
    log.error(node, "field " .. node.field .. " is not valid")
  end
  return setter_info
end

property_setters:register_setter("task", "target", std.processor_type,
                                 {fn = c.bishop_task_set_target_processor})
property_setters:register_setter("task", "target", std.processor_list_type,
                                 {fn = c.bishop_task_set_target_processor_list,
                                  cleanup = c.bishop_delete_processor_list})
property_setters:register_setter("region", "target", std.memory_type,
                                 {fn = c.bishop_region_set_target_memory})
property_setters:register_setter("region", "target", std.memory_list_type,
                                 {fn = c.bishop_region_set_target_memory_list,
                                  cleanup = c.bishop_delete_memory_list})

local processor_isa = {
  x86 = c.X86_ISA,
  cuda = c.CUDA_ISA,
}

local memory_kind = {
  global = c.GLOBAL_MEM,
  sysmem = c.SYSTEM_MEM,
  regmem = c.REGDMA_MEM,
  fbmem = c.GPU_FB_MEM,
  zcmem = c.Z_COPY_MEM,
  disk = c.DISK_MEM,
  hdf = c.HDF_MEM,
  l1cache = c.LEVEL1_CACHE,
  l2cache = c.LEVEL2_CACHE,
  l3cache = c.LEVEL3_CACHE,
}

function codegen.type(ty)
  if std.is_processor_type(ty) then
    return c.legion_processor_t
  elseif std.is_processor_list_type(ty) then
    return c.bishop_processor_list_t
  elseif std.is_memory_type(ty) then
    return c.legion_memory_t
  elseif std.is_memory_list_type(ty) then
    return c.bishop_memory_list_t
  elseif std.is_isa_type(ty) then
    return c.legion_processor_kind_t
  elseif std.is_memory_kind_type(ty) then
    return c.legion_memory_kind_t
  elseif std.is_point_type(ty) then
    return &int
  elseif ty == int then
    return ty
  else
    assert(false, "type '" .. tostring(ty) .. "' should not be used for " ..
      "actual terra code generation")
  end
end

function codegen.expr(binders, node)
  local value = terralib.newsymbol(codegen.type(node.expr_type))
  local actions = quote
    var [value]
  end

  if node:is(ast.typed.expr.Keyword) then
    local keyword = node.value
    if keyword == "processors" then
      assert(std.is_processor_list_type(node.expr_type))
      actions = quote
        [actions];
        [value] = c.bishop_all_processors()
      end
    elseif std.is_isa_type(node.expr_type) then
      actions = quote
        [actions];
        [value] = [ processor_isa[keyword] ]
      end
    elseif std.is_memory_kind_type(node.expr_type) then
      actions = quote
        [actions];
        [value] = [ memory_kind[keyword] ]
      end
    else
      log.error(node, "keyword " .. keyword .. " is not yet supported")
    end

  elseif node:is(ast.typed.expr.Unary) then
    local rhs = codegen.expr(binders, node.rhs)
    actions = quote
      [rhs.actions];
      [actions];
      [value] = [std.quote_unary_op(node.op, rhs.value)]
    end

  elseif node:is(ast.typed.expr.Binary) then
    local lhs = codegen.expr(binders, node.lhs)
    local rhs = codegen.expr(binders, node.rhs)
    actions = quote
      [lhs.actions];
      [rhs.actions];
      [actions];
      [value] = [std.quote_binary_op(node.op, lhs.value, rhs.value)]
    end

  elseif node:is(ast.typed.expr.Filter) then
    local base = codegen.expr(binders, node.value)
    actions = quote
      [actions];
      [base.actions];
      [value] = [base.value]
    end
    node.constraints:map(function(constraint)
      assert(constraint:is(ast.typed.FilterConstraint))
      local v = codegen.expr(binders, constraint.value)
      if constraint.field == "isa" then
        assert(std.is_processor_list_type(node.value.expr_type))
        assert(std.is_isa_type(constraint.value.expr_type))
        actions = quote
          [actions];
          [v.actions];
          [value] = c.bishop_filter_processors_by_isa([value], [v.value])
          if [value].size == 0 then
            c.bishop_logger_warning("expression '%s' yields an empty list",
              [node:unparse()])
          end
          c.bishop_delete_processor_list([base.value])
        end

      elseif constraint.field == "kind" then
        assert(std.is_memory_list_type(node.value.expr_type))
        assert(std.is_memory_kind_type(constraint.value.expr_type))
        actions = quote
          [actions];
          [v.actions];
          [value] = c.bishop_filter_memories_by_kind([value], [v.value])
          if [value].size == 0 then
            c.bishop_logger_warning("expression '%s' yields an empty list",
              [node:unparse()])
          end
          c.bishop_delete_memory_list([base.value])
        end

      else
        assert(false, "unreachable")
      end
    end)

  elseif node:is(ast.typed.expr.Index) then
    local base = codegen.expr(binders, node.value)
    local index = codegen.expr(binders, node.index)
    actions = quote
      [actions];
      [base.actions];
      [index.actions];
      do
        std.assert([index.value] >= 0 and [index.value] < [base.value].size,
          ["index " .. tostring(index.value) .. " is out-of-bounds"])
        [value] = [base.value].list[ [index.value] ]
      end
    end
  elseif node:is(ast.typed.expr.Field) then
    if node.field == "memories" then
      local base = codegen.expr(binders, node.value)
      actions = quote
        [actions];
        [base.actions];
        do
          [value] = c.bishop_filter_memories_by_visibility([base.value])
          if [value].size == 0 then
            c.bishop_logger_warning("  expression '%s' yields an empty list",
              [node:unparse()])
          end
        end
      end
    else
      log.error(node, "field " .. node.field  ..  " is not supported")
    end
  elseif node:is(ast.typed.expr.Constant) then
    actions = quote
      [actions];
      [value] = [node.value]
    end
  elseif node:is(ast.typed.expr.Variable) then
    assert(binders[node.value])
    actions = quote
      [actions];
      [value] = [ binders[node.value] ]
    end
  end

  return {
    actions = actions,
    value = value,
  }
end

function codegen.property(binders, rule_type, obj_var, node)
  local setter_info = property_setters:find_setter(rule_type, node)
  local value = codegen.expr(binders, node.value)
  local actions = quote
    [value.actions];
    var result = [setter_info.fn]([obj_var], [value.value])
    if not result then
      c.bishop_logger_warning("  property '%s' was not properly assigned",
        node.field)
    end
  end
  if setter_info.cleanup then
    actions = quote
      [actions];
      [setter_info.cleanup]([value.value])
    end
  end
  return actions
end

function codegen.task_rule(node)
  local task_var = terralib.newsymbol(c.legion_task_t)
  local is_matched = terralib.newsymbol(bool)
  local selector_body = quote var [is_matched] = true end
  local selector = node.selector
  local position_string = node.position.filename .. ":" ..
    tostring(node.position.linenumber)
  assert(#selector.elements > 0)
  local first_element = selector.elements[1]
  assert(first_element:is(ast.typed.element.Task))
  local binders = {}

  if #first_element.name > 0 then
    assert(#first_element.name == 1)
    local task_name = terralib.constant(first_element.name[1])
    selector_body = quote
      [selector_body];
      var name = c.legion_task_get_name([task_var])
      [is_matched] = [is_matched] and (c.strcmp(name, [task_name]) == 0)
    end
  end

  local select_task_options_body = quote end
  node.properties:map(function(property)
    select_task_options_body = quote
      [select_task_options_body];
      [codegen.property(binders, "task", task_var, property)]
    end
  end)

  local terra select_task_options([task_var] : c.legion_task_t)
    [selector_body];
    if [is_matched] then
      c.bishop_logger_info("[select_task_options] rule at %s matches",
        position_string)
      [select_task_options_body]
    else
      c.bishop_logger_info("[select_task_options] rule at %s was not applied",
        position_string)
    end
  end

  return {
    select_task_options = select_task_options,
    pre_map_task = 0,
    select_task_variant = 0,
    map_task = 0,
  }
end

function codegen.region_rule(node)
  local task_var = terralib.newsymbol(c.legion_task_t)
  local req_var = terralib.newsymbol(c.legion_region_requirement_t)
  local is_matched = terralib.newsymbol(bool)
  local selector_body = quote var [is_matched] = true end
  local selector = node.selector
  local position_string = node.position.filename .. ":" ..
    tostring(node.position.linenumber)
  assert(#selector.elements > 1)
  local first_element = selector.elements[1]
  assert(first_element:is(ast.typed.element.Region))
  local first_task_element = selector.elements[2]
  assert(first_task_element:is(ast.typed.element.Task))
  local binders = {}

  if #first_task_element.name > 0 then
    assert(#first_task_element.name == 1)
    local task_name = terralib.constant(first_task_element.name[1])
    selector_body = quote
      [selector_body];
      var name = c.legion_task_get_name([task_var])
      [is_matched] = [is_matched] and (c.strcmp(name, [task_name]) == 0)
    end
  end

  local pattern_matches = quote end
  first_task_element.patterns:map(function(pattern)
    if pattern.field == "target" then
      local binder = terralib.newsymbol(pattern.binder)
      binders[pattern.binder] = binder
      pattern_matches = quote
        [pattern_matches];
        var [binder] : c.legion_processor_t
        [binder] = c.legion_task_get_target_proc([task_var])
      end
    else
      log.error(node, "field " .. pattern.field ..
      " is not supported for pattern match")
    end
  end)

  local constraint_checks = quote end

  local map_task_body = quote end
  node.properties:map(function(property)
    map_task_body = quote
      [map_task_body];
      [codegen.property(binders, "region", req_var, property)]
    end
  end)

  local early_out = quote
    if not [is_matched] then
      c.bishop_logger_info("[map_task] rule at %s was not applied",
        position_string)
      return
    end
  end

  local terra map_task([task_var] : c.legion_task_t,
                       [req_var] : c.legion_region_requirement_t)
    [selector_body];
    [early_out];
    [pattern_matches];
    [constraint_checks];
    [early_out];
    c.bishop_logger_info("[map_task] rule at %s matches", position_string)
    [map_task_body]
  end

  return {
    select_task_options = 0,
    pre_map_task = 0,
    select_task_variant = 0,
    map_task = map_task,
  }
end

function codegen.rules(node)
  local rules = terralib.newlist()
  rules:insertall(node.task_rules:map(codegen.task_rule))
  rules:insertall(node.region_rules:map(codegen.region_rule))
  node.region_rules:map(codegen.region_rule)
  return rules
end

return codegen
