%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2016, 2600Hz
%%% @doc
%%% Listen for CDR events and record them to the database
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%   Edouard Swiac
%%%   Ben Wann
%%%-------------------------------------------------------------------
-module(cdr_listener).
-behaviour(gen_listener).

%% API
-export([start_link/0]).
-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-include("cdr.hrl").
-define(VIEW_TO_UPDATE, <<"cdrs/interaction_listing">>).
-define(THRESHOLD, kapps_config:get(?CONFIG_CAT, <<"refresh_view_threshold">>, 0)).
-define(TIMEOUT, kapps_config:get(?CONFIG_CAT, <<"refresh_timeout">>, 900)).

-record(state, {counter = #{} :: map()}).
-type state() :: #state{}.

-define(SERVER, ?MODULE).

-define(RESPONDERS, [{'cdr_channel_destroy'
                     ,[{<<"call_event">>, <<"CHANNEL_DESTROY">>}]
                     }
                    ]).
-define(BINDINGS, [{'call'
                   ,[{'restrict_to', ['CHANNEL_DESTROY']}]
                   }
                  ]).
-define(QUEUE_NAME, <<"cdr_listener">>).
-define(QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(CONSUME_OPTIONS, [{'exclusive', 'false'}]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Starts the server
%%--------------------------------------------------------------------
-spec start_link() -> startlink_ret().
start_link() ->
    gen_listener:start_link(?SERVER, [{'responders', ?RESPONDERS}
                                     ,{'bindings', ?BINDINGS}
                                     ,{'queue_name', ?QUEUE_NAME}
                                     ,{'queue_options', ?QUEUE_OPTIONS}
                                     ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec init([]) -> {'ok', state()}.
init([]) ->

    lager:info("cdr refresher threshold: ~p, timeout: ~p", [?THRESHOLD, ?TIMEOUT]),
    erlang:send_after(?TIMEOUT*?MILLISECONDS_IN_SECOND, self(), timeout),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_call(any(), pid_ref(), state()) -> handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(any(), state()) -> handle_cast_ret_state(state()).
handle_cast(_Msg, State) ->
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_info(any(), state()) -> handle_info_ret_state(state()).
handle_info(timeout, #state{counter = Counter} = State) ->
    Now = kz_util:current_tstamp(),
    Timeout = ?TIMEOUT,
    HandleTimeout =
        fun(AccountId, {Map, List}) ->
                {From, Count} = maps:get(AccountId, Map),
                case Now - From > Timeout
                    andalso Count > 0 of
                    true -> { Map#{ AccountId => {Now, 0} }, [{AccountId, From, Now} | List] };
                    false -> {Map, List}
                end
        end,
    {NewCounter, RefreshList} = lists:foldl(HandleTimeout, {Counter, []}, maps:keys(Counter)),
    maybe_spawn_refresh_process(RefreshList),
    erlang:send_after(Timeout*?MILLISECONDS_IN_SECOND, self(), timeout),
    {noreply, State#state{ counter = NewCounter } };
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State}.

-spec maybe_spawn_refresh_process([{ne_binary(), gregorian_seconds(), gregorian_seconds()}]) -> any().
maybe_spawn_refresh_process([]) -> ok;
maybe_spawn_refresh_process(RefreshList) ->
    _ = kz_util:spawn(fun update_accounts_view/1, [RefreshList]).

-spec handle_event(kz_json:object(), state()) -> gen_listener:handle_event_return().
handle_event(JObj, #state{} = State) -> handle_event(JObj, State, ?THRESHOLD).

-spec handle_event(kz_json:object(), state(), non_neg_integer()) -> gen_listener:handle_event_return().
handle_event(_JObj, #state{}, 0) -> {reply, []};
handle_event(JObj, State, Threshold) ->
    handle_account(State, Threshold, kz_json:get_value([<<"Custom-Channel-Vars">>, <<"Account-ID">>], JObj)).

-spec handle_account(state(), non_neg_integer(), ne_binary()) -> gen_listener:handle_event_return().
handle_account(#state{}, _, undefined) -> {reply, []};
handle_account(#state{counter = Counter} = State, Threshold, AccountId) ->
    Count = case value(maps:find(AccountId, Counter)) of
                {From, Threshold} ->
                    _ = kz_util:spawn(fun update_account_view/3, [AccountId, From, kz_util:current_tstamp()]),
                    {kz_util:current_tstamp(), 0};
                {From, Value} -> {From, Value + 1}
            end,
    {reply, [], State#state{ counter = Counter#{ AccountId => Count }} }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("cdr listener terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

value({ok, Value}) -> Value;
value(_) -> {kz_util:current_tstamp(), 0}.

-spec update_account_view(ne_binary(), gregorian_seconds(), gregorian_seconds()) -> any().
update_account_view(AccountId, From, To) ->
    Dbs = kazoo_modb:get_range(AccountId, From, To),
    lager:info("refresh cdr view account:~p db:~p from:~p to:~p", [AccountId, Dbs, From, To]),
    [ kz_datamgr:get_results(Db, ?VIEW_TO_UPDATE, [{startkey, From}, {endkey, To}]) || Db <- Dbs ].

-spec update_accounts_view([{ne_binary(), gregorian_seconds(), gregorian_seconds()}]) -> any().
update_accounts_view(UpdateList) ->
    [ update_account_view(AccountId, From, To) || {AccountId, From, To} <- UpdateList ].
