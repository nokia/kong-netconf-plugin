--[[Lincensed under BSD 3 Clause License
SPDX-License-Identifier: BSD-3-Clause
Copyright, 2019 Nokia]]

local BasePlugin = require "kong.plugins.base_plugin"
local NetconfHandler = BasePlugin:extend()
local luaxml = require "LuaXML"
local lpty = require "lpty"
local semaphore = require "ngx.semaphore"
local ngx = ngx
local ptysema = semaphore.new()
ptysema:post(1)
local hellomsgseparator = "]]>]]>"

local function CleanupUpstreams(connectedupstreams)
    local upstream = nil
    local upstreamdata = nil
    for upstream, upstreamdata in pairs(connectedupstreams) do
        local ok, err = ptysema:wait(2)
        if not ok then
            kong.log.err("Semaphore is not ready, could not release upstreams: ", err)
            return ngx.exit(499)
        else
            kong.log.debug("CleanupUpstreams obtained control over the pty")
        end
        local upstreampty = upstreamdata[1]
        if upstreampty and upstreampty:hasproc() then
            kong.log.debug("Terminating upstream:", upstream)
            upstreampty:endproc()
        end
        upstreamdata = nil
        ptysema:post(1)
    end
    connectedupstreams = {}
    return ngx.exit(499)
end

local function CreateXMLdoc(data)
    return string.gsub(tostring(data),'\r*\n%#(%d+)\r*\n',"")
end

local function ReplaceDashWithUnderscore(data)
    return string.gsub(data, "message%-id", "message__id")
end

local function ReplaceUnderscoreWithDash(data)
    return string.gsub(data, "message%__id", "message-id")
end

local function TrimReadHelloMsg(data)
    local first, last = string.find(data,"<hello", 1, true)
    if first then
        data = string.sub(data, first)
    else
        kong.log.err("Invalid hello msg 1")
        return nil
    end
    first, last = string.find(data, "</hello>", 1, true)
    if first then
        data = string.sub(data, 1, last)
    else
        kong.log.err("Invalid hello msg 2")
        return nil
    end
    return data
end

local function CreateHelloMsg(config)
    local body = xml.new("hello")
    body.xmlns = "urn:ietf:params:xml:ns:netconf:base:1.0"
    local capabilities = body:append("capabilities")
    if not capabilities then
        kong.log.err("Cannot add capabilities to the hello msg")
        return nil
    end
    if config.capability_upstream then
        for k,v in pairs(config.capability_upstream) do
            capabilities:append("capability")[1]=tostring(k)
        end
        if not config.capability_upstream["urn:ietf:params:netconf:base:1.1"] then
            capabilities:append("capability")[1]="urn:ietf:params:netconf:base:1.1"
        end
    end
    math.randomseed(os.time())
    local downstreamsessionid = math.random(65535) --poor man's session ID generator. Otherwise we would need a globally unique number, administerd in the state DB of Kong. TODO
    body:append("session-id")[1] = downstreamsessionid
    return '<?xml version="1.0" encoding="UTF-8"?>\n' .. tostring(body:str()) .. hellomsgseparator .. "\n", downstreamsessionid
end

local function ParseUpstreamFromConfig(upstreamfromconfig)
    local fields = {}
    upstreamfromconfig.destination:gsub("([^:]+)", function(c) fields[#fields+1] = c end)
    return fields[1], fields[2]
end

local function ReadUntilPattern(pty, pattern, plain, timeout)
	if not pty:hasproc() then return nil, "no running process." end
	local data = ""
	local found = false
    while not found do
        while pty:hasproc() and not pty:readok(1) do end --wait until the child side of the pty is ready to be read
        if pty:hasproc() then
            kong.log.debug("pty ready to be read")
    		local r, err = pty:read(timeout)
	    	if r ~= nil then
                data = data .. r
                kong.log.debug("data so far:", data)
                kong.log.debug("pattern to match:", pattern)
                local first, last, capture = data:find(pattern, 1, plain)
                if first then
                    data = string.sub(data, 1, first-1)
			    	return data
                end
		    else
			    if err then
                    kong.log.debug("ReadUntilPattern pty read failed: ", tostring(err))
			    else
				    local what, code = pty:exitstatus()
				    if what then
                        kong.log.debug("ReadUntilPattern pty read failed: child process terminated because of " .. tostring(what) .. " " .. tostring(code))
                        return nil
				    end
			    end
		    end
        else
            local what, code = pty:exitstatus()
			if what then
                kong.log.debug("ReadUntilPattern pty read failed 2: child process terminated because of " .. tostring(what) .. " " .. tostring(code))
            end
            return nil
        end
    end
    return nil
end

function SendToUpstream(pty, message)
    ngx.sleep(0.5) --[[ we always sleep a bit before we send anything to the upstream. Dirty trick to let the pty buffers (or whatever) get into
                    a state where sending something is successful after a reading. ]]
    local ok, err = ptysema:wait(2)
    if not ok then
        kong.log.err("Semaphore is not ready, could not send message: ", err)
        return 0
    else
        kong.log.debug("SendToUpstream obtained control over the pty")
    end
    local sentbytes = 0
    local parts = 0
    while sentbytes < message:len() do
        while pty:hasproc() and not pty:sendok() do end --wait until the child side of the pty is ready to receive data
        local partialbytes = pty:send(message:sub(sentbytes+1)) 
        if not partialbytes then 
            kong.log.err("could not send the msg to the upstream")
            ptysema:post(1)
            return 0
        else
            sentbytes = sentbytes + partialbytes
        end
        parts  = parts + 1
    end
    if sentbytes > 0 and sentbytes >= message:len() then
        kong.log.debug("Message was sent to upstream in parts:", parts)
    end
    ptysema:post(1)
    return sentbytes
end

local function SSHWithPassword(user, host, upstreamport, secret_prefix)
    local passwordfile = secret_prefix.."/"..user.."/".."password"
    local userhost = user .. "@" ..host
    kong.log.debug("User@host:", userhost)
    local f = assert(io.open(passwordfile, "r"))
    local pw = f:read()
    pw = pw .. "\n"
    f:close()
    local pty = lpty.new({no_local_echo=true})
    if pty then 
        local success = pty:startproc("/usr/bin/ssh", userhost, "-p", upstreamport, "-oStrictHostKeyChecking=no", "-s", "netconf") --accepting all upstream server keys is UGLY! TODO
        if success then
            kong.log.debug("ssh connection initiated")
            local data = ReadUntilPattern(pty, "assword:", true, 3)
            if data then
                kong.log.debug("ssh password prompt received: ", tostring(data))
                local sentbytes = SendToUpstream(pty, pw)
                if sentbytes then
                    kong.log.debug("ssh password sent", sentbytes)
                    return pty
                else
                    kong.log.err("could not send password")
                    pty:endproc()
                    return nil
                end
            else
                kong.log.err("password prompt is not received")
                pty:endproc()
                return nil
            end
        else
            kong.log.err("ssh initiation is unsuccessful")
            return nil
        end
    else
        kong.log.err("pty object cannot be created")
        return nil
    end
end

local function SSHWithKey(user, host, upstreamport, secret_prefix)
    local keyfile = secret_prefix.."/"..user.."/".."key"
    local userhost = user .. "@" ..host
    kong.log.debug("User@host:", userhost)
    local pty = lpty:new({no_local_echo=true}) 
    if pty then 
        local success = pty:startproc("/usr/bin/ssh", userhost, "-i", keyfile, "-p", upstreamport, "-oStrictHostKeyChecking=no", "-s", "netconf") --accepting all upstream server keys is ugly! TODO
        if success then
            kong.log.debug("ssh connection initiated with key based authentication")
            return pty
        else
            kong.log.err("ssh connection establishment is unsuccessful")
            return nil
        end
    else
        kong.log.err("pty object cannot be created")
        return nil
    end
end

local function ConnectToUpstream(upstreamfromconfig, netconfuser, secret_prefix, clienthellomsg)
    local host, upstreamport = ParseUpstreamFromConfig(upstreamfromconfig)
    if host == nil or upstreamport == nil then
        kong.log.err("Upstream host or port cannot be parsed from the config")
        return nil
    end
    local pty = nil
    local upstreamsessionid = nil
    if upstreamfromconfig.auth_method == "password" then
        pty = SSHWithPassword(netconfuser, host, upstreamport, secret_prefix)
        if not pty then
            kong.log.err("could not establish ssh connection to upstream")
            return nil
        end
    elseif upstreamfromconfig.auth_method == "key" then
        pty = SSHWithKey(netconfuser, host, upstreamport, secret_prefix) 
        if not pty then
            kong.log.err("could not establish ssh connection to upstream")
            return nil
        end
    else
        kong.log.err("unsupported ssh authentication method:", tostring(upstreamfromconfig.auth.method))
        return nil
    end
    if pty and pty:hasproc() then
        kong.log.debug("waiting for hello msg from upstream")
        local data = ReadUntilPattern(pty, "]]>]]>", true, 5)
        if data then
            kong.log.debug("read hello from upstream: ", tostring(data))
            helloxml = TrimReadHelloMsg(data)
            local xmltable = xml.eval(tostring(helloxml))
            if xmltable then
                if xmltable[0] == "hello" then
                    sessionid = xmltable:find("session-id")
                    if sessionid then
                        upstreamsessionid = sessionid[1]
                        kong.log.debug("session id from the upstream:", tostring(upstreamsessionid))
                    else
                        kong.log.err("no session id from the upstream")
                        pty:endproc()
                        return nil
                    end
                else
                    kong.log.err("first msg from the upstream is not hello")
                    pty:endproc()
                    return nil
                end
            else
                kong.log.err("first msg from the upstream is not a valid hello msg")
                pty:endproc()
                return nil
            end
        else
            kong.log.err("No hello msg from upstream")
            pty:endproc()
            return nil
        end
        kong.log.debug("Hello message to upstream:", clienthellomsg)
        local sentbytes = SendToUpstream(pty, clienthellomsg)
        if sentbytes == 0 then
            kong.log.err("Could not send hello msg to upstream")
            pty:endproc()
            return nil
        end
        kong.log.debug("hello message is sent to upstream")
        return pty, upstreamsessionid
    else
        kong.log.err("Could not establish ssh connection to upstream")
        return nil
    end
end

local function ReplaceSessionID(xmltable, newsessionid)
    sessionid = xmltable:find("session-id")
    if sessionid then
        sessiond[1] = newsessionid
    else
        kong.log.debug("no session id in the message")
    end
    return xmltable:str()
end

local function HandleUpstream(connectedupstreams, downstreamdata)
    local downstream_socket = nil
    while true do
        kong.log.inspect("Connected upstreams: ", connectedupstreams)
        if downstreamdata then
            downstream_socket = downstreamdata[1]
        end
        if downstream_socket == nil then
            kong.log.debug("there is no downstream socket anymore, exiting")
            return                    
        end
        for upstream, upstreamdata in pairs(connectedupstreams) do
            ok, err = ptysema:wait(2)
            if not ok then
                kong.log.err("Could not read upstream ptys, semaphore is not ready:", err)
                break
            else
                kong.log.debug("HandleUpstream obtained control over the pty")
            end
            kong.log.debug("upstream pty:", upstreamdata[1])
            local upstreampty = upstreamdata[1]
            if upstreampty and upstreampty:hasproc() then
                kong.log.debug("Trying reading from the upstream")
                if upstreampty:readok() then
                    kong.log.debug("There is data to be read from the upstream")
                    local data = ReadUntilPattern(upstreampty, "\r*\n##\r*\n", false, 1) --some terminals insert \r for fun
                    if data then
                        kong.log.debug("read data from upstream: ", tostring(data))
                        local xmldoc = CreateXMLdoc(data) -- See RFC6242. NETCONF messages are not vanilla XML documents, but they are in a chunked framing format
                        kong.log.debug("data in XML format: ", xmldoc)
                        xmldoc = ReplaceDashWithUnderscore(xmldoc) -- we do this as "-" is a special character in Lua and cannot be used as a character in a key in a table
                        local xmltable = xml.eval(tostring(xmldoc))
                        if xmltable then
                            if xmltable[0] == "rpc-reply" or xmltable[0] == "rpc-error"then
                                local message = ReplaceSessionID(xmltable, downstreamsessionid)
                                if not message then
                                    kong.log.err("Could not replace session ID in downstream direction")
                                else
                                    message = ReplaceUnderscoreWithDash(message)
                                    message = "\n#" .. tostring(message:len()) .. "\n" .. message .. "\n##\n"
                                    local bytes, err = downstream_socket:send(message)
                                    if err then
                                        kong.log.err("Failed to send the message to downstream msg", err)
                                    end
                                end
                            else
                                kong.log.err("Message from upstream is not rpc-reply. Ignored")
                            end
                        else
                            kong.log.err("Message from upstream is not vaild. Ignored")
                        end
                    else
                        kong.log.err("No data from upstream")
                    end
                else
                    kong.log.debug("Upstream has no data to be read")
                end
            else
                if upstreampty then
                    local what, code = upstreampty:exitstatus()
			        if what then
                        kong.log.debug("Handleupstream: upstream process terminated because of " .. tostring(what) .. " " .. tostring(code))
                    end
                    upstreampty:endproc()
                end
                connectedupstreams[upstream] = nil
                kong.log.debug("Zombie connection record removed")
            end
            ptysema:post(1)       
        end
        ngx.sleep(0.3) --[[ we have to use this dirty trick here. As the pty is not a resource under the supervision
                            of nginx/openresty the operations on the pty will not resume this light thread when a pty
                            is ready for reading. We must make sure that it is awaken periodically]]
    end
end

function NetconfHandler:new()
    NetconfHandler.super.new(self, "netconf-plugin")
end

function NetconfHandler:init_worker()
    NetconfHandler.super.init_worker(self)
end

function NetconfHandler:preread(config)
    NetconfHandler.super.preread(self)
    kong.log.debug("netconf plugin started")
    local connectedupstreams = {}
    local downstreamdata = {}
    local msgseparator = "\n##\n"
    local clienthellomsg = ""
    local downstreamsessionid = nil
    local downstream_socket, err = ngx.req.socket(true)
    local netconfuser = ""
    local netconfuserfile = "/tmp/netconfusers/"..tostring(ngx.var.remote_port)
    kong.log.debug("client port file: ", netconfuserfile)
    if err then
       kong.log.err("failed to obtain downstrem socket: ", tostring(err))
       return ngx.exit(500)
    end

    while netconfuser == "" do
        local f = io.open(netconfuserfile, "r")
        if f then
            netconfuser = f:read()
            f:close()
            os.remove(netconfuserfile)
        end
    end
    kong.log.debug("netconfuser: ", netconfuser)

    local ownhellomsg, downstreamsessionid = CreateHelloMsg(config)
    if ownhellomsg then
        kong.log.debug("Contructed own hello msg:", ownhellomsg)
        local bytes, err = downstream_socket:send(ownhellomsg)
        if err then
            kong.log.err("Failed to send the hello msg to downstream")
            return ngx.exit(500)
        else
            kong.log.debug("Hello msg sent to downstream:", bytes)
        end
    else
        kong.log.err("Cannot construct own hello msg for downstream")
        return ngx.exit(500)
    end
    local reader = downstream_socket:receiveuntil(hellomsgseparator)  --the first operation is "hello" on a new connection and it must be terninated with the string ]]>]]> See RFC6242
    local data, err, partial = reader(config.max_msg_size)
    if err then
        kong.log.err("failed to read the downstream socket: ", tostring(err))
        return ngx.exit(500)
    end
    if not partial then
        -- partial is nil, i.e. we could read the message in one part and it is smaller than the max_msg_size
        if not data then
            -- data is nil something went wrong
            kong.log.err("nil data received ")
            return ngx.exit(400)
        end
        kong.log.debug("read data: ", tostring(data))
        local xmltable = xml.eval(tostring(data)) 
        if not xmltable then
            kong.log.err("The received data is not a valid XML. Exit.")
            return ngx.exit(400)
        end
        kong.log.inspect("xml in table format:", xmltable)
        if not xmltable[0] then
            kong.log.err("The received XML has no tag. Exit.")
            return ngx.exit(400)
        end
        kong.log.debug("msg type: ", tostring(xmltable[0]))
        if not err then
            if tostring(xmltable[0]) == "hello" then
                if xmltable:find("session%-id") then
                    kong.log.err("Hello message contains session-id, error")
                    return ngx.exit(400)
                end
                clienthellomsg = tostring(data) .. hellomsgseparator.. "\n"
            else
                kong.log.err("The first message from the client must be a hello message")
                return ngx.exit(400)
            end
        else
            kong.log.err("Could not parse the message for the message type")
            return ngx.exit(400)            
        end
    else
        -- too long message. We have read 4MB of data but still could not see the message terminator string pattern. We stop the processing of the message.
        kong.log.err("Too big NETCONF message. We stop processing ")
        return ngx.exit(413)
    end
    
    local defaultupstream = config.capability_upstream["urn:ietf:params:netconf:base:1.1"]

    downstreamdata[1] = downstream_socket
    downstreamdata[2] = downstreamsessionid
    local UpstreamThread = ngx.thread.spawn(HandleUpstream, connectedupstreams, downstreamdata)
    if not UpstreamThread then
        kong.log.err("Failed to spawn the upstream thread: ", err)
        return ngx.exit(500)
    end

    local downstreamreader = downstream_socket:receiveuntil(msgseparator)
    downstream_socket:settimeout(1000) 
    while true do
        kong.log.debug("In the while loop")
        local data, err, partial = downstreamreader(config.max_msg_size)
        kong.log.debug("After the downstreamreader")
        kong.log.debug("downstream err: ", err)
        kong.log.debug("downstream partial:", partial)
        kong.log.debug("downstream data:", data)
        if err then
            if err == "closed" then 
                kong.log.debug("Downstream socket closed")
                downstreamdata[1] = nil
                return ngx.exit(499)
            elseif err ~= "timeout" then
                kong.log.err("Failed to read the downstream socket: ", tostring(err))
                return ngx.exit(499)
            end
        end
        if data then
            if not partial then
                kong.log.debug("read data from downstream: ", tostring(data))
                local xmldoc = CreateXMLdoc(data) -- See RFC6242. NETCONF messages are not vanilla XML documents, but they are in a chunked framing format
                xmldoc = ReplaceDashWithUnderscore(xmldoc) -- we do this as "-" is a special character in Lua and cannot be used as a character in a key in a table
                kong.log.debug("data in XML format: ", xmldoc)
                local xmltable = xml.eval(tostring(xmldoc))
                if xmltable then
                    kong.log.inspect("xml in table format:", xmltable)
                    if xmltable[0] == "rpc" then
                        if xmltable[1] then
                            local operation = tostring(xmltable[1][0])
                            local operationnamespace = tostring(xmltable[1].xmlns)
                            kong.log.debug("operation: ", tostring(operation))
                            kong.log.debug("operation namespace: ", tostring(operationnamespace))
                            local upstreamfromconfig = defaultupstream
                            if operationnamespace and config.capability_upstream[operationnamespace] then
                                upstreamfromconfig = config.capability_upstream[operationnamespace]
                            end
                            local pty = nil
                            local upstreamsessionid = nil
                            if connectedupstreams[upstreamfromconfig.destination] and connectedupstreams[upstreamfromconfig.destination][1]:hasproc() then
                                kong.log.debug("there is an existing connection to the selected upstream, we re-use that connection")
                                pty = connectedupstreams[upstreamfromconfig.destination][1]
                                upstreamsessionid = connectedupstreams[upstreamfromconfig.destination][2]
                            else    
                                kong.log.debug("there is no connection to the selected upstream, creating a new connection")
                                pty, upstreamsessionid = ConnectToUpstream(upstreamfromconfig, netconfuser, config.secret_prefix, clienthellomsg)
                                if not pty then
                                    kong.log.err("could not connect to upstream")
                                    return ngx.exit(500)
                                end
                                connectedupstreams[upstreamfromconfig.destination] = {pty, upstreamsessionid}
                            end
                            local message = ReplaceSessionID(xmltable, connectedupstreams[upstreamfromconfig.destination][2])
                            if not message then
                                kong.log.err("could not replace the session ID towards upstream")
                                return ngx.exit(500)
                            end
                            message = ReplaceUnderscoreWithDash(message)
                            local sentbytes = 0
                            local msg_len = message:len()
                            local message = "\n#" .. tostring(msg_len) .. "\n" .. message .. "\n##\n"
                            kong.log.debug("Message to be sent to upstream:", message)
                            local sentbytes = SendToUpstream(pty, message)
                            if sentbytes == 0 then 
                                kong.log.err("Could not send the message to upstream")
                                return ngx.exit(500)
                            end
                        else
                            kong.log.err("rpc message from downstream without operation code. Ignored")
                        end
                    else
                        kong.log.err("Message from downstream is not rpc. Ignored")
                    end
                else
                    kong.log.err("Invalid message format from downstream. Ignored")
                end
            else
                -- too long message. We have read the configured max size of data but still could not see the message terminator string pattern. We stop the processing of the session.
                kong.log.err("Too big NETCONF message. We stop processing ")
                return ngx.exit(413)
            end
        else
            kong.log.debug("No data from downstream")
        end
    end
    return ngx.exit(200)
end

function NetconfHandler:log(config)
    NetconfHandler.super.log(self)
end

-- NetconfHandler.PRIORITY = 770
NetconfHandler.VERSION = "0.0.1-1"

return NetconfHandler
