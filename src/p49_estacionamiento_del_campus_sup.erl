-module(p49_estacionamiento_del_campus_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% rest_for_one: registro debe existir antes que las zonas; si cae el
%% registro, se reinicia todo el dominio para no dejar procesos huerfanos.
init([]) ->
    Children = [
        #{id => p49_registro,
          start => {p49_registro, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker},
        #{id => p49_zonas_sup,
          start => {p49_zonas_sup, start_link, []},
          restart => permanent,
          shutdown => infinity,
          type => supervisor},
        #{id => p49_estacionamiento_del_campus_server,
          start => {p49_estacionamiento_del_campus_server, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker},
        #{id => p49_http,
          start => {p49_http, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker}
    ],
    {ok, {#{strategy => rest_for_one, intensity => 10, period => 60}, Children}}.
