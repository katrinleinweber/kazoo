%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(kazoo_token_buckets_sup).

-behaviour(supervisor).

-export([start_link/0
        ,buckets_srv/0
        ]).
-export([init/1]).

-include("kz_buckets.hrl").

-define(SERVER, ?MODULE).

%% Helper macro for declaring children of supervisor
-define(CHILDREN, [?SUPER('kz_buckets_sup')
                  ,?WORKER_ARGS('kazoo_etsmgr_srv'
                               ,[
                                 [{'table_id', kz_buckets:table_id()}
                                 ,{'table_options', kz_buckets:table_options()}
                                 ,{'find_me_function', fun buckets_srv/0}
                                 ,{'gift_data', kz_buckets:gift_data()}
                                 ]
                                ])
                  ,?WORKER('kz_buckets')
                  ]).

%% ===================================================================
%% API functions
%% ===================================================================

%%--------------------------------------------------------------------
%% @public
%% @doc Starts the supervisor
%%--------------------------------------------------------------------
-spec start_link() -> startlink_ret().
start_link() ->
    supervisor:start_link({'local', ?SERVER}, ?MODULE, []).

-spec buckets_srv() -> api_pid().
buckets_srv() ->
    case [P || {'kz_buckets', P, _, _} <- supervisor:which_children(?SERVER)] of
        [] -> 'undefined';
        [P] -> P
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%% @end
%%--------------------------------------------------------------------
-spec init(any()) -> sup_init_ret().
init([]) ->
    RestartStrategy = 'one_for_one',
    MaxRestarts = 5,
    MaxSecondsBetweenRestarts = 10,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    {'ok', {SupFlags, ?CHILDREN}}.
