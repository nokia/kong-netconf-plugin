--[[Lincensed under BSD 3 Clause License
SPDX-License-Identifier: BSD-3-Clause
Copyright, 2019 Nokia]]

local typedefs = require "kong.db.schema.typedefs"

return {
  name = "netconf",
  fields = {
    { consumer = typedefs.no_consumer },
    { config = {
      type = "record",
      fields = {
        { max_msg_size = {
          type = "number",
          required = false,
          default = 4194304
        }},
        { secret_prefix = {
          type = "string",
          required = false,
          default = "/tmp/password"
        }},
        { capability_upstream = {
          type = "map",
          keys = { type = "string" },
          values = { type = "record",
                     fields = {
                       { destination = {
                         type = "string",
                         required = true
                       }},
                       { auth_method = {
                         type = "string",
                         required = true
                       }},
                     }
                    },                        
          required = false,
          default = {
            ["urn:ietf:params:netconf:base:1.0"] = {destination = "127.0.0.1:38830", auth_method = "password"},
            ["urn:ietf:params:netconf:base:1.1"] = {destination = "127.0.0.1:38830", auth_method = "password"}
           }
        }}
      }
    }}
  }
}
