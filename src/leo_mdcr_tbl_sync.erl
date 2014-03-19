%%======================================================================
%%
%% Leo Redundant Manager
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%======================================================================
-module(leo_mdcr_tbl_sync).

-author('Yosuke Hara').

-behaviour(gen_server).

-include("leo_redundant_manager.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/2,
         stop/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
	       terminate/2,
         code_change/3]).

-record(state, {
          server_type :: atom(),
          managers = []    :: list(atom()),
          interval = 30000 :: integer()
         }).

-ifdef(TEST).
-define(DEF_MEMBERSHIP_INTERVAL, 500).
-define(DEF_TIMEOUT, 1000).
-else.
-define(DEF_MEMBERSHIP_INTERVAL, 20000).
-define(DEF_TIMEOUT, 10000).
-endif.


%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
start_link(ServerType, Managers) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,
                          [ServerType, Managers, ?DEF_MEMBERSHIP_INTERVAL], []).

stop() ->
    gen_server:call(?MODULE, stop, 30000).


%%--------------------------------------------------------------------
%% GEN_SERVER CALLBACKS
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State}          |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
init([ServerType, Managers, Interval]) ->
    {ok, #state{
            server_type = ServerType,
            managers = Managers,
            interval = Interval}, Interval}.


handle_call(stop,_From,State) ->
    {stop, normal, ok, State}.


%% Function: handle_cast(Msg, State) -> {noreply, State}          |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
handle_cast(_, #state{interval = Interval} = State) ->
    {noreply, State, Interval}.


%% Function: handle_info(Info, State) -> {noreply, State}          |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
handle_info(timeout, #state{server_type = ServerType,
                            managers = Managers,
                            interval = Interval} = State) ->
    Delay = 250,
    timer:sleep(erlang:phash2(leo_date:clock(), Delay) + Delay),

    %% Synchronize mdcr-related tables
    spawn(fun() ->
                  sync_tables(ServerType, Managers)
          end),
    {noreply, State, Interval};

handle_info(_Info, #state{interval = Interval} = State) ->
    {noreply, State, Interval}.


%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
terminate(_Reason, _State) ->
    ok.

%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%--------------------------------------------------------------------
%% INTERNAL FUNCTIONS
%%--------------------------------------------------------------------
%% @doc Synchronize mdcr-related tables
%% @private
-spec(sync_tables(atom(), list(atom())) ->
             ok).
sync_tables(gateway,_Managers) ->
    ok;
sync_tables(manager,_Managers) ->
    Redundancies = ?rnd_nodes_from_ring(),
    case sync_tables_1(Redundancies) of
        ok ->
            ok;
        {Node, BadItems} ->
            {ok, [Mod, Method]} = application:get_env(?APP, ?PROP_SYNC_MF),
            case erlang:apply(Mod, Method, [BadItems, erlang:node(), Node]) of
                ok ->
                    ok;
                {error, Cause} ->
                    {error, Cause}
            end
    end;
sync_tables(_ServerType, []) ->
    ok;
sync_tables(ServerType, [Manager|Rest]) ->
    case sync_tables_1(?rnd_nodes_from_ring()) of
        ok ->
            ok;
        {Node, BadItems} ->
            {ok, [Mod, Method]} = ?env_sync_mod_and_method(),
            case rpc:call(Manager, Mod, Method,
                          [BadItems, erlang:node(), Node], ?DEF_TIMEOUT) of
                ok ->
                    ok;
                _Error ->
                    sync_tables(ServerType, Rest)
            end
    end.

%% @private
sync_tables_1([]) ->
    ok;
sync_tables_1([#redundant_node{node = Node,
                               available = true}|Rest]) when Node == erlang:node() ->
    sync_tables_1(Rest);
sync_tables_1([#redundant_node{node = Node,
                               available = true}|Rest]) ->
    case rpc:call(Node, leo_redundant_manager_api, get_remote_clusters, []) of
        {ok, ResL_1} ->
            {ok, ResL_2} = leo_redundant_manager_api:get_remote_clusters(),
            case check_consistency(ResL_1, ResL_2) of
                [] ->
                    ok;
                BadItems ->
                    {Node, BadItems}
            end;
        _Other ->
            sync_tables_1(Rest)
    end;
sync_tables_1([_Node|Rest]) ->
    sync_tables_1(Rest).

%% @private
check_consistency(L1, L2) ->
    check_consistency([?CHKSUM_CLUSTER_INFO,
                       ?CHKSUM_CLUSTER_MGR,
                       ?CHKSUM_CLUSTER_MEMBER,
                       ?CHKSUM_CLUSTER_STAT], L1, L2, []).
check_consistency([],_L1,_L2, Acc) ->
    Acc;
check_consistency([Item|Rest], L1, L2, Acc) ->
    case (leo_misc:get_value(Item, L1) == leo_misc:get_value(Item, L2)) of
        true  -> check_consistency(Rest, L1, L2, Acc);
        false -> check_consistency(Rest, L1, L2, [Item|Acc])
    end.
