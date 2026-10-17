-- Desktop libcamera discovery after the local seat becomes active.
-- Based on WirePlumber's libcamera enumeration and BlueZ seat monitoring.
-- Copyright (c) 2023 Collabora Ltd.
-- SPDX-License-Identifier: MIT

log = Log.open_topic ("s-sp7-libcamera-seat")
config = Conf.get_section_as_properties ("monitor.libcamera.properties")
monitor = nil

function createCamDevice (parent, id, type, factory, properties)
  local source = Plugin.find ("standard-event-source")
  local event = source:call ("create-event", "create-libcamera-device", parent, nil)
  event:set_data ("device-properties", properties)
  event:set_data ("factory", factory)
  event:set_data ("device-sub-id", id)
  EventDispatcher.push_event (event)
end

function updateSeat (state)
  if state == "active" then
    if monitor then return end
    log:info ("Local seat active; starting desktop camera discovery")
    monitor = SpaDevice ("api.libcamera.enum.manager", config)
    if monitor then
      monitor:connect ("create-object", createCamDevice)
      monitor:activate (Feature.SpaDevice.ENABLED)
    else
      log:warning ("Could not create the libcamera monitor")
    end
  elseif monitor then
    log:info ("Local seat inactive; releasing desktop camera discovery")
    monitor:deactivate (Feature.SpaDevice.ENABLED)
    monitor = nil
  end
end

local logind = Plugin.find ("logind")
assert (logind, "SP7 desktop camera discovery requires logind")
logind:connect ("state-changed", function (_, state) updateSeat (state) end)
updateSeat (logind:call ("get-state"))
