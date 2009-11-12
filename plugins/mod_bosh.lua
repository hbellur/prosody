-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module.host = "*" -- Global module

local hosts = _G.hosts;
local lxp = require "lxp";
local init_xmlhandlers = require "core.xmlhandlers"
local server = require "net.server";
local httpserver = require "net.httpserver";
local sm = require "core.sessionmanager";
local sm_destroy_session = sm.destroy_session;
local new_uuid = require "util.uuid".generate;
local fire_event = require "core.eventmanager".fire_event;
local core_process_stanza = core_process_stanza;
local st = require "util.stanza";
local logger = require "util.logger";
local log = logger.init("mod_bosh");

local xmlns_bosh = "http://jabber.org/protocol/httpbind"; -- (hard-coded into a literal in session.send)
local stream_callbacks = { stream_tag = "http://jabber.org/protocol/httpbind\1body", default_ns = xmlns_bosh };

local BOSH_DEFAULT_HOLD = tonumber(module:get_option("bosh_default_hold")) or 1;
local BOSH_DEFAULT_INACTIVITY = tonumber(module:get_option("bosh_max_inactivity")) or 60;
local BOSH_DEFAULT_POLLING = tonumber(module:get_option("bosh_max_polling")) or 5;
local BOSH_DEFAULT_REQUESTS = tonumber(module:get_option("bosh_max_requests")) or 2;
local BOSH_DEFAULT_MAXPAUSE = tonumber(module:get_option("bosh_max_pause")) or 300;

local default_headers = { ["Content-Type"] = "text/xml; charset=utf-8" };
local session_close_reply = { headers = default_headers, body = st.stanza("body", { xmlns = xmlns_bosh, type = "terminate" }), attr = {} };

local t_insert, t_remove, t_concat = table.insert, table.remove, table.concat;
local os_time = os.time;

local sessions = {};
local inactive_sessions = {}; -- Sessions which have no open requests

-- Used to respond to idle sessions (those with waiting requests)
local waiting_requests = {};
function on_destroy_request(request)
	waiting_requests[request] = nil;
	local session = sessions[request.sid];
	if session then
		local requests = session.requests;
		for i,r in pairs(requests) do
			if r == request then requests[i] = nil; break; end
		end
		
		-- If this session now has no requests open, mark it as inactive
		if #requests == 0 and session.bosh_max_inactive and not inactive_sessions[session] then
			inactive_sessions[session] = os_time();
			(session.log or log)("debug", "BOSH session marked as inactive at %d", inactive_sessions[session]);
		end
	end
end

function handle_request(method, body, request)
	if (not body) or request.method ~= "POST" then
		return "<html><body>You really don't look like a BOSH client to me... what do you want?</body></html>";
	end
	if not method then 
		log("debug", "Request %s suffered error %s", tostring(request.id), body);
		return;
	end
	--log("debug", "Handling new request %s: %s\n----------", request.id, tostring(body));
	request.notopen = true;
	request.log = log;
	local parser = lxp.new(init_xmlhandlers(request, stream_callbacks), "\1");
	
	parser:parse(body);
	
	local session = sessions[request.sid];
	if session then
		local r = session.requests;
		log("debug", "Session %s has %d out of %d requests open", request.sid, #r, session.bosh_hold);
		log("debug", "and there are %d things in the send_buffer", #session.send_buffer);
		if #r > session.bosh_hold then
			-- We are holding too many requests, send what's in the buffer,
			log("debug", "We are holding too many requests, so...");
			if #session.send_buffer > 0 then
				log("debug", "...sending what is in the buffer")
				session.send(t_concat(session.send_buffer));
				session.send_buffer = {};
			else
				-- or an empty response
				log("debug", "...sending an empty response");
				session.send("");
			end
		elseif #session.send_buffer > 0 then
			log("debug", "Session has data in the send buffer, will send now..");
			local resp = t_concat(session.send_buffer);
			session.send_buffer = {};
			session.send(resp);
		end
		
		if not request.destroyed and session.bosh_wait then
			request.reply_before = os_time() + session.bosh_wait;
			request.on_destroy = on_destroy_request;
			waiting_requests[request] = true;
		end
		
		log("debug", "Have nothing to say, so leaving request unanswered for now");
		return true;
	end
end


local function bosh_reset_stream(session) session.notopen = true; end

local function bosh_close_stream(session, reason)
	(session.log or log)("info", "BOSH client disconnected");
	session_close_reply.attr.condition = reason;
	for _, held_request in ipairs(session.requests) do
		held_request:send(session_close_reply);
		held_request:destroy();
	end
	sessions[session.sid]  = nil;
	sm_destroy_session(session);
end

function stream_callbacks.streamopened(request, attr)
	log("debug", "BOSH body open (sid: %s)", attr.sid);
	local sid = attr.sid
	if not sid then
		-- New session request
		request.notopen = nil; -- Signals that we accept this opening tag
		
		-- TODO: Sanity checks here (rid, to, known host, etc.)
		if not hosts[attr.to] then
			-- Unknown host
			log("debug", "BOSH client tried to connect to unknown host: %s", tostring(attr.to));
			session_close_reply.body.attr.condition = "host-unknown";
			request:send(session_close_reply);
			request.notopen = nil
			return;
		end
		
		-- New session
		sid = new_uuid();
		local session = { type = "c2s_unauthed", conn = {}, sid = sid, rid = tonumber(attr.rid), host = attr.to, bosh_version = attr.ver, bosh_wait = attr.wait, streamid = sid, 
						bosh_hold = BOSH_DEFAULT_HOLD, bosh_max_inactive = BOSH_DEFAULT_INACTIVITY,
						requests = { }, send_buffer = {}, reset_stream = bosh_reset_stream, close = bosh_close_stream, 
						dispatch_stanza = core_process_stanza, log = logger.init("bosh"..sid), secure = request.secure };
		sessions[sid] = session;
		
		log("info", "New BOSH session, assigned it sid '%s'", sid);
		local r, send_buffer = session.requests, session.send_buffer;
		local response = { headers = default_headers }
		function session.send(s)
			log("debug", "Sending BOSH data: %s", tostring(s));
			local oldest_request = r[1];
			while oldest_request and oldest_request.destroyed do
				t_remove(r, 1);
				waiting_requests[oldest_request] = nil;
				oldest_request = r[1];
			end
			if oldest_request then
				log("debug", "We have an open request, so using that to send with");
				response.body = t_concat{"<body xmlns='http://jabber.org/protocol/httpbind' sid='", sid, "' xmlns:stream = 'http://etherx.jabber.org/streams'>", tostring(s), "</body>" };
				oldest_request:send(response);
				--log("debug", "Sent");
				if oldest_request.stayopen then
					if #r>1 then
						-- Move front request to back
						t_insert(r, oldest_request);
						t_remove(r, 1);
					end
				else
					log("debug", "Destroying the request now...");
					oldest_request:destroy();
					t_remove(r, 1);
				end
			elseif s ~= "" then
				log("debug", "Saved to send buffer because there are %d open requests", #r);
				-- Hmm, no requests are open :(
				t_insert(session.send_buffer, tostring(s));
				log("debug", "There are now %d things in the send_buffer", #session.send_buffer);
			end
		end
		
		-- Send creation response
		
		local features = st.stanza("stream:features");
		fire_event("stream-features", session, features);
		--xmpp:version='1.0' xmlns:xmpp='urn:xmpp:xbosh'
		local response = st.stanza("body", { xmlns = xmlns_bosh, 
									inactivity = tostring(BOSH_DEFAULT_INACTIVITY), polling = tostring(BOSH_DEFAULT_POLLING), requests = tostring(BOSH_DEFAULT_REQUESTS), hold = tostring(session.bosh_hold), maxpause = "120", 
									sid = sid, authid = sid, ver  = '1.6', from = session.host, secure = 'true', ["xmpp:version"] = "1.0", 
									["xmlns:xmpp"] = "urn:xmpp:xbosh", ["xmlns:stream"] = "http://etherx.jabber.org/streams" }):add_child(features);
		request:send{ headers = default_headers, body = tostring(response) };
				
		request.sid = sid;
		return;
	end
	
	local session = sessions[sid];
	if not session then
		-- Unknown sid
		log("info", "Client tried to use sid '%s' which we don't know about", sid);
		request:send{ headers = default_headers, body = tostring(st.stanza("body", { xmlns = xmlns_bosh, type = "terminate", condition = "item-not-found" })) };
		request.notopen = nil;
		return;
	end
	
	if session.rid then
		local rid = tonumber(attr.rid);
		local diff = rid - session.rid;
		if diff > 1 then
			session.log("warn", "rid too large (means a request was lost). Last rid: %d New rid: %s", session.rid, attr.rid);
		elseif diff <= 0 then
			-- Repeated, ignore
			session.log("debug", "rid repeated (on request %s), ignoring: %d", request.id, session.rid);
			request.notopen = nil;
			t_insert(session.requests, request);
			return;
		end
		session.rid = rid;
	end
	
	if attr.type == "terminate" then
		-- Client wants to end this session
		session:close();
		request.notopen = nil;
		return;
	end
	
	-- If session was inactive, make sure it is now marked as not
	if #session.requests == 0 then
		(session.log or log)("debug", "BOSH client now active again at %d", os_time());
		inactive_sessions[session] = nil;
	end
	
	if session.notopen then
		local features = st.stanza("stream:features");
		fire_event("stream-features", session, features);
		session.send(features);
		session.notopen = nil;
	end
	
	request.notopen = nil; -- Signals that we accept this opening tag
	t_insert(session.requests, request);
	request.sid = sid;
end

function stream_callbacks.handlestanza(request, stanza)
	log("debug", "BOSH stanza received: %s\n", stanza:top_tag());
	local session = sessions[request.sid];
	if session then
		if stanza.attr.xmlns == xmlns_bosh then
			stanza.attr.xmlns = "jabber:client";
		end
		core_process_stanza(session, stanza);
	end
end

local dead_sessions = {};
function on_timer()
	-- log("debug", "Checking for requests soon to timeout...");
	-- Identify requests timing out within the next few seconds
	local now = os_time() + 3;
	for request in pairs(waiting_requests) do
		if request.reply_before <= now then
			log("debug", "%s was soon to timeout, sending empty response", request.id);
			-- Send empty response to let the
			-- client know we're still here
			if request.conn then
				sessions[request.sid].send("");
			end
		end
	end
	
	now = now - 3;
	local n_dead_sessions = 0;
	for session, inactive_since in pairs(inactive_sessions) do
		if session.bosh_max_inactive then
			if now - inactive_since > session.bosh_max_inactive then
				(session.log or log)("debug", "BOSH client inactive too long, destroying session at %d", now);
				sessions[session.sid]  = nil;
				inactive_sessions[session] = nil;
				n_dead_sessions = n_dead_sessions + 1;
				dead_sessions[n_dead_sessions] = session;
			end
		else
			inactive_sessions[session] = nil;
		end
	end

	for i=1,n_dead_sessions do
		local session = dead_sessions[i];
		dead_sessions[i] = nil;
		sm_destroy_session(session, "BOSH client silent for over "..session.bosh_max_inactive.." seconds");
	end
end

local ports = module:get_option("bosh_ports") or { 5280 };
httpserver.new_from_config(ports, handle_request, { base = "http-bind" });

server.addtimer(on_timer);
