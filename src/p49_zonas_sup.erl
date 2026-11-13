-module(p49_zonas_sup).
-behaviour(supervisor).

-export([start_link/0, init/1, nombre/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

nombre(ZonaId) ->
    binary_to_atom(<<"p49_zona_sup_", ZonaId/binary>>, utf8).

init([]) ->
    Hijos = [#{id => maps:get(id, Zona),
               start => {p49_zona_sup, start_link, [maps:get(id, Zona)]},
               restart => permanent,
               shutdown => infinity,
               type => supervisor}
             || Zona <- p49_config:zonas()],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 60}, Hijos}}.
