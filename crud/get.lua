local checks = require('checks')
local errors = require('errors')
local vshard = require('vshard')

local call = require('crud.common.call')
local utils = require('crud.common.utils')
local sharding = require('crud.common.sharding')
local sharding_key_module = require('crud.common.sharding_key')
local dev_checks = require('crud.common.dev_checks')
local schema = require('crud.common.schema')

local GetError = errors.new_class('GetError', {capture_stack = false})

local get = {}

local GET_FUNC_NAME = '_crud.get_on_storage'

local function get_on_storage(space_name, key, field_names)
    dev_checks('string', '?', '?table')

    local space = box.space[space_name]
    if space == nil then
        return nil, GetError:new("Space %q doesn't exist", space_name)
    end

    -- add_space_schema_hash is false because
    -- reloading space format on router can't avoid get error on storage
    return schema.wrap_box_space_func_result(space, 'get', {key}, {
        add_space_schema_hash = false,
        field_names = field_names,
    })
end

function get.init()
   _G._crud.get_on_storage = get_on_storage
end

-- returns result, err, need_reload
-- need_reload indicates if reloading schema could help
-- see crud.common.schema.wrap_func_reload()
local function call_get_on_router(space_name, key, opts)
    dev_checks('string', '?', {
        timeout = '?number',
        bucket_id = '?number|cdata',
        fields = '?table',
        prefer_replica = '?boolean',
        balance = '?boolean',
        mode = '?string',
    })

    opts = opts or {}

    local space = utils.get_space(space_name, vshard.router.routeall())
    if space == nil then
        return nil, GetError:new("Space %q doesn't exist", space_name), true
    end

    if box.tuple.is(key) then
        key = key:totable()
    end

    local sharding_key = key
    if opts.bucket_id == nil then
        local err
        local primary_index_parts = space.index[0].parts
        sharding_key, err = sharding_key_module.extract_from_pk(space_name, primary_index_parts, key)
        if err ~= nil then
            return nil, err
        end
    end

    local bucket_id = sharding.key_get_bucket_id(sharding_key, opts.bucket_id)
    local call_opts = {
        mode = opts.mode or 'read',
        prefer_replica = opts.prefer_replica,
        balance = opts.balance,
        timeout = opts.timeout,
    }
    local storage_result, err = call.single(
        bucket_id, GET_FUNC_NAME,
        {space_name, key, opts.fields},
        call_opts
    )

    if err ~= nil then
        return nil, GetError:new("Failed to call get on storage-side: %s", err)
    end

    if storage_result.err ~= nil then
        return nil, GetError:new("Failed to get: %s", storage_result.err)
    end

    local tuple = storage_result.res

    -- protect against box.NULL
    if tuple == nil then
        tuple = nil
    end

    return utils.format_result({tuple}, space, opts.fields)
end

--- Get tuple from the specified space by key
--
-- @function call
--
-- @param string space_name
--  A space name
--
-- @param key
--  Primary key value
--
-- @tparam ?number opts.timeout
--  Function call timeout
--
-- @tparam ?number opts.bucket_id
--  Bucket ID
--  (by default, it's vshard.router.bucket_id_strcrc32 of primary key)
--
-- @tparam ?boolean opts.prefer_replica
--  Call on replica if it's possible
--
-- @tparam ?boolean opts.balance
--  Use replica according to round-robin load balancing
--
-- @return[1] object
-- @treturn[2] nil
-- @treturn[2] table Error description
--
function get.call(space_name, key, opts)
    checks('string', '?', {
        timeout = '?number',
        bucket_id = '?number|cdata',
        fields = '?table',
        prefer_replica = '?boolean',
        balance = '?boolean',
        mode = '?string',
    })

    return schema.wrap_func_reload(call_get_on_router, space_name, key, opts)
end

return get
