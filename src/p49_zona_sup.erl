-module(p49_zona_sup).
-behaviour(supervisor).

-export([start_link/1, init/1, nombre/1]).

start_link(ZonaId) ->
    supervisor:start_link({local, nombre(ZonaId)}, ?MODULE, [ZonaId]).

nombre(ZonaId) ->
    binary_to_atom(<<"p49_zona_sup_", ZonaId/binary>>, utf8).

%% rest_for_one: primero los cajones (sensores) y luego el coordinador de
%% la zona. Si muere el supervisor de cajones, la zona tambien se reinicia
%% y reconstruye su ocupacion leyendo los cajones nuevos.
init([ZonaId]) ->
    Hijos = [
        #{id => cajon_sup,
          start => {p49_cajon_sup, start_link, [ZonaId]},
          restart => permanent,
          shutdown => infinity,
          type => supervisor},
        #{id => zona,
          start => {p49_zona, start_link, [ZonaId]},
          restart => permanent,
          shutdown => 5000,
          type => worker}
    ],
    {ok, {#{strategy => rest_for_one, intensity => 20, period => 60}, Hijos}}.
