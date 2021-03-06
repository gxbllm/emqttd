%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2015 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% MQTT Client Connection.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttd_client).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

-include("emqttd_internal.hrl").

-behaviour(gen_server).

%% API Function Exports
-export([start_link/2, session/1, info/1, kick/1]).

%% SUB/UNSUB Asynchronously, called by plugins.
-export([subscribe/2, unsubscribe/2]).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

%% Client State
-record(client_state, {connection, connname, peername, peerhost, peerport,
                       await_recv, conn_state, rate_limit, parser_fun,
                       proto_state, packet_opts, keepalive}).

-define(INFO_KEYS, [peername, peerhost, peerport, await_recv, conn_state]).

-define(SOCK_STATS, [recv_oct, recv_cnt, send_oct, send_cnt]).

-define(LOG(Level, Format, Args, State),
            lager:Level("Client(~s): " ++ Format, [State#client_state.connname | Args])).

start_link(Connection, MqttEnv) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [[Connection, MqttEnv]])}.

session(CPid) ->
    gen_server:call(CPid, session, infinity).

info(CPid) ->
    gen_server:call(CPid, info, infinity).

kick(CPid) ->
    gen_server:call(CPid, kick).

subscribe(CPid, TopicTable) ->
    gen_server:cast(CPid, {subscribe, TopicTable}).

unsubscribe(CPid, Topics) ->
    gen_server:cast(CPid, {unsubscribe, Topics}).

init([OriginConn, MqttEnv]) ->
    {ok, Connection} = OriginConn:wait(),
    {PeerHost, PeerPort, PeerName} =
    case Connection:peername() of
        {ok, Peer = {Host, Port}} ->
            {Host, Port, Peer};
        {error, enotconn} ->
            Connection:fast_close(),
            exit(normal);
        {error, Reason} ->
            Connection:fast_close(),
            exit({shutdown, Reason})
    end,
    ConnName = esockd_net:format(PeerName),
    SendFun = fun(Data) ->
        try Connection:async_send(Data) of
            true -> ok
        catch
            error:Error -> exit({shutdown, Error})
        end
    end,
    PktOpts = proplists:get_value(packet, MqttEnv),
    ParserFun = emqttd_parser:new(PktOpts),
    ProtoState = emqttd_protocol:init(PeerName, SendFun, PktOpts),
    RateLimit = proplists:get_value(rate_limit, Connection:opts()),
    State = run_socket(#client_state{connection   = Connection,
                                     connname     = ConnName,
                                     peername     = PeerName,
                                     peerhost     = PeerHost,
                                     peerport     = PeerPort,
                                     await_recv   = false,
                                     conn_state   = running,
                                     rate_limit   = RateLimit,
                                     parser_fun   = ParserFun,
                                     proto_state  = ProtoState,
                                     packet_opts  = PktOpts}),
    ClientOpts = proplists:get_value(client, MqttEnv),
    IdleTimout = proplists:get_value(idle_timeout, ClientOpts, 10),
    gen_server:enter_loop(?MODULE, [], State, timer:seconds(IdleTimout)).

handle_call(session, _From, State = #client_state{proto_state = ProtoState}) -> 
    {reply, emqttd_protocol:session(ProtoState), State};

handle_call(info, _From, State = #client_state{connection  = Connection,
                                               proto_state = ProtoState}) ->
    ClientInfo = ?record_to_proplist(client_state, State, ?INFO_KEYS),
    ProtoInfo  = emqttd_protocol:info(ProtoState),
    {ok, SockStats} = Connection:getstat(?SOCK_STATS),
    {reply, lists:append([ClientInfo, [{proto_info, ProtoInfo},
                                       {sock_stats, SockStats}]]), State};

handle_call(kick, _From, State) ->
    {stop, {shutdown, kick}, ok, State};

handle_call(Req, _From, State) ->
    ?LOG(critical, "Unexpected request: ~p", [Req], State),
    {reply, {error, unsupported_request}, State}.

handle_cast({subscribe, TopicTable}, State) ->
    with_session(fun(SessPid) ->
                   emqttd_session:subscribe(SessPid, TopicTable)
                 end, State);

handle_cast({unsubscribe, Topics}, State) ->
    with_session(fun(SessPid) ->
                   emqttd_session:unsubscribe(SessPid, Topics)
                 end, State);

handle_cast(Msg, State) ->
    ?LOG(critical, "Unexpected msg: ~p", [Msg], State),
    noreply(State).

handle_info(timeout, State) ->
    shutdown(idle_timeout, State);

%% Asynchronous SUBACK
handle_info({suback, PacketId, GrantedQos}, State) ->
    with_proto_state(fun(ProtoState) ->
                       Packet = ?SUBACK_PACKET(PacketId, GrantedQos),
                       emqttd_protocol:send(Packet, ProtoState)
                     end, State);

handle_info({deliver, Message}, State) ->
    with_proto_state(fun(ProtoState) ->
                       emqttd_protocol:send(Message, ProtoState)
                     end, State);

handle_info({redeliver, {?PUBREL, PacketId}}, State) ->
    with_proto_state(fun(ProtoState) ->
                       emqttd_protocol:redeliver({?PUBREL, PacketId}, ProtoState)
                     end, State);

handle_info({shutdown, conflict, {ClientId, NewPid}}, State) ->
    ?LOG(warning, "clientid '~s' conflict with ~p", [ClientId, NewPid], State),
    shutdown(conflict, State);

handle_info(activate_sock, State) ->
    hibernate(run_socket(State#client_state{conn_state = running}));

handle_info({inet_async, _Sock, _Ref, {ok, Data}}, State) ->
    Size = size(Data),
    ?LOG(debug, "RECV ~p", [Data], State),
    emqttd_metrics:inc('bytes/received', Size),
    received(Data, rate_limit(Size, State#client_state{await_recv = false}));

handle_info({inet_async, _Sock, _Ref, {error, Reason}}, State) ->
    shutdown(Reason, State);

handle_info({inet_reply, _Sock, ok}, State) ->
    hibernate(State);

handle_info({inet_reply, _Sock, {error, Reason}}, State) ->
    shutdown(Reason, State);

handle_info({keepalive, start, Interval}, State = #client_state{connection = Connection}) ->
    ?LOG(debug, "Keepalive at the interval of ~p", [Interval], State),
    StatFun = fun() ->
                case Connection:getstat([recv_oct]) of
                    {ok, [{recv_oct, RecvOct}]} -> {ok, RecvOct};
                    {error, Error}              -> {error, Error}
                end
             end,
    KeepAlive = emqttd_keepalive:start(StatFun, Interval, {keepalive, check}),
    hibernate(State#client_state{keepalive = KeepAlive});

handle_info({keepalive, check}, State = #client_state{keepalive = KeepAlive}) ->
    case emqttd_keepalive:check(KeepAlive) of
        {ok, KeepAlive1} ->
            hibernate(State#client_state{keepalive = KeepAlive1});
        {error, timeout} ->
            ?LOG(debug, "Keepalive timeout", [], State),
            shutdown(keepalive_timeout, State);
        {error, Error} ->
            ?LOG(warning, "Keepalive error - ~p", [Error], State),
            shutdown(Error, State)
    end;

handle_info(Info, State) ->
    ?LOG(critical, "Unexpected info: ~p", [Info], State),
    noreply(State).

terminate(Reason, #client_state{connection  = Connection,
                                keepalive   = KeepAlive,
                                proto_state = ProtoState}) ->
    Connection:fast_close(),
    emqttd_keepalive:cancel(KeepAlive),
    case {ProtoState, Reason} of
        {undefined, _} ->
            ok;
        {_, {shutdown, Error}} ->
            emqttd_protocol:shutdown(Error, ProtoState);
        {_, Reason} ->
            emqttd_protocol:shutdown(Reason, ProtoState)
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

with_proto_state(Fun, State = #client_state{proto_state = ProtoState}) ->
    {ok, ProtoState1} = Fun(ProtoState),
    hibernate(State#client_state{proto_state = ProtoState1}).

with_session(Fun, State = #client_state{proto_state = ProtoState}) ->
    Fun(emqttd_protocol:session(ProtoState)),
    hibernate(State).

%% receive and parse tcp data
received(<<>>, State) ->
    hibernate(State);

received(Bytes, State = #client_state{parser_fun  = ParserFun,
                                      packet_opts = PacketOpts,
                                      proto_state = ProtoState}) ->
    case catch ParserFun(Bytes) of
        {more, NewParser}  ->
            noreply(run_socket(State#client_state{parser_fun = NewParser}));
        {ok, Packet, Rest} ->
            emqttd_metrics:received(Packet),
            case emqttd_protocol:received(Packet, ProtoState) of
                {ok, ProtoState1} ->
                    received(Rest, State#client_state{parser_fun = emqttd_parser:new(PacketOpts),
                                                      proto_state = ProtoState1});
                {error, Error} ->
                    ?LOG(error, "Protocol error - ~p", [Error], State),
                    shutdown(Error, State);
                {error, Error, ProtoState1} ->
                    shutdown(Error, State#client_state{proto_state = ProtoState1});
                {stop, Reason, ProtoState1} ->
                    stop(Reason, State#client_state{proto_state = ProtoState1})
            end;
        {error, Error} ->
            ?LOG(error, "Framing error - ~p", [Error], State),
            shutdown(Error, State);
        {'EXIT', Reason} ->
            ?LOG(error, "Parser failed for ~p", [Reason], State),
            ?LOG(error, "Error data: ~p", [Bytes], State),
            shutdown(parser_error, State)
    end.

rate_limit(_Size, State = #client_state{rate_limit = undefined}) ->
    run_socket(State);
rate_limit(Size, State = #client_state{rate_limit = Rl}) ->
    case Rl:check(Size) of
        {0, Rl1} ->
            run_socket(State#client_state{conn_state = running, rate_limit = Rl1});
        {Pause, Rl1} ->
            ?LOG(error, "Rate limiter pause for ~p", [Pause], State),
            erlang:send_after(Pause, self(), activate_sock),
            State#client_state{conn_state = blocked, rate_limit = Rl1}
    end.

run_socket(State = #client_state{conn_state = blocked}) ->
    State;
run_socket(State = #client_state{await_recv = true}) ->
    State;
run_socket(State = #client_state{connection = Connection}) ->
    Connection:async_recv(0, infinity),
    State#client_state{await_recv = true}.

noreply(State) ->
    {noreply, State}.

hibernate(State) ->
    {noreply, State, hibernate}.

shutdown(Reason, State) ->
    stop({shutdown, Reason}, State).

stop(Reason, State) ->
    {stop, Reason, State}.

