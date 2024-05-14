# Ekvm

scaleable stable database written in motoko.
db variable should be set like so:

stable var db : ?EkvmModule.Ekvm = null;

and then set from within an init function using the create function:

db := ?EkvmModule.create(...);

to PUT a listing in the database pass the db to the put function with like so:

EkvmModule.put(db, index, value);

to GET a query from the databse by its index use

EkvmModule.get(db, index);