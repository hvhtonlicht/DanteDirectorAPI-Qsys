-- Experimental routing engine. Copy into a Q-SYS script or bundle with UI code.
-- No credentials are stored here. All operations are asynchronous.
local json = require("rapidjson")
local Routing = {}
function Routing.new(getKey)
  local self = {}
  local busy = false
  local function request(query, variables, callback)
    local key = getKey()
    if type(key) ~= "string" or key == "" then callback(false,"Missing API key"); return end
    HttpClient.Upload({
      Url = "https://api.director.dante.cloud/graphql",
      Method = "POST", Timeout = 15,
      Headers = {["Content-Type"]="application/json", Authorization=key},
      Data = json.encode({query=query, variables=variables}),
      EventHandler = function(_, code, body, err)
        if code ~= 200 then callback(false,"HTTP "..tostring(code)); return end
        local ok, result = pcall(json.decode, body or "")
        if not ok or type(result) ~= "table" then callback(false,"Invalid JSON response"); return end
        if result.errors then callback(false,"GraphQL error: "..json.encode(result.errors)); return end
        if type(result.data) ~= "table" then callback(false,"Missing GraphQL data"); return end
        callback(true,result.data)
      end
    })
  end
  function self.domains(callback)
    request("query { domains { id name } }", {}, callback)
  end
  function self.discover(domainId, callback)
    request([[query Devices($domainId: ID!) {
      domain(id: $domainId) { devices { id name
        status { connectivity subscriptions }
        txChannels { index name }
        rxChannels { index name subscribedDevice subscribedChannel status }
      } }
    }]], {domainId=domainId}, callback)
  end
  local mutation = [[mutation DeviceRxChannelsSubscriptionSet($input: DeviceRxChannelsSubscriptionSetInput!) {
    DeviceRxChannelsSubscriptionSet(input: $input) { ok }
  }]]
  -- routes: array of {deviceId,rxChannelIndex,subscribedDevice,subscribedChannel}
  -- Empty transmitter names clear a route. Unspecified receivers are untouched.
  -- The callback reports submission, NOT established audio.
  function self.apply(routes, callback)
    if busy then callback(false,{error="Routing operation already in progress"}); return end
    if type(routes) ~= "table" or #routes == 0 then callback(false,{error="Empty preset"}); return end
    local groups, order, seen = {}, {}, {}
    for _, r in ipairs(routes) do
      if type(r) ~= "table" or type(r.deviceId) ~= "string" or r.deviceId == ""
        or type(r.rxChannelIndex) ~= "number" or r.rxChannelIndex < 1 or r.rxChannelIndex % 1 ~= 0
        or type(r.subscribedDevice) ~= "string" or type(r.subscribedChannel) ~= "string"
        or ((r.subscribedDevice == "") ~= (r.subscribedChannel == "")) then
        callback(false,{error="Invalid route"}); return
      end
      if not groups[r.deviceId] then
        groups[r.deviceId] = {}; seen[r.deviceId] = {}; order[#order+1] = r.deviceId
      end
      if seen[r.deviceId][r.rxChannelIndex] then callback(false,{error="Duplicate receiver channel"}); return end
      seen[r.deviceId][r.rxChannelIndex] = true
      table.insert(groups[r.deviceId], {rxChannelIndex=r.rxChannelIndex, subscribedDevice=r.subscribedDevice, subscribedChannel=r.subscribedChannel})
    end
    busy = true
    local results = {}
    local function nextGroup(i)
      local id = order[i]
      if not id then
        busy = false
        local all = true
        for _, result in ipairs(results) do if not result.accepted then all = false end end
        callback(all,results); return
      end
      request(mutation,{input={deviceId=id,subscriptions=groups[id]}},function(ok,data)
        local accepted = ok and type(data.DeviceRxChannelsSubscriptionSet) == "table" and data.DeviceRxChannelsSubscriptionSet.ok == true
        results[#results+1] = {deviceId=id,accepted=accepted, error=not accepted and (ok and "Mutation rejected" or data) or nil}
        nextGroup(i+1)
      end)
    end
    nextGroup(1)
  end
  function self.verify(domainId, routes, callback)
    self.discover(domainId,function(ok,data)
      if not ok then callback(false,data); return end
      local devices = {}
      for _, dev in ipairs((data.domain or {}).devices or {}) do devices[dev.id]=dev end
      local results, all = {}, true
      for _, r in ipairs(routes) do
        local found
        for _, ch in ipairs((devices[r.deviceId] or {}).rxChannels or {}) do
          if ch.index == r.rxChannelIndex then found=ch; break end
        end
        local matches = found ~= nil and (found.subscribedDevice or "") == r.subscribedDevice and (found.subscribedChannel or "") == r.subscribedChannel
        results[#results+1] = {deviceId=r.deviceId,rxChannelIndex=r.rxChannelIndex,matches=matches,status=found and found.status}
        if not matches then all=false end
      end
      callback(all,results)
    end)
  end
  return self
end
return Routing
