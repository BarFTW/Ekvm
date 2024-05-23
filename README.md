# Ekvm - Elastic Key-Value Store in Motoko

Ekvm is a highly scalable key-value store library written in Motoko, designed to leverage stable memory for infinitely scalable data storage on the Internet Computer. This library is optimized for distributed applications requiring persistent and efficient data storage.

Features
* Infinite Scalability: Utilizes stable memory to handle large amounts of data without sacrificing performance.
* Elastic Storage: Automatically adjusts to the growing data needs of your application.
* High Performance: Optimized for fast read and write operations.
* Persistence: Ensures data durability and consistency across upgrades and restarts.

Installation
To use Ekvm in your Motoko project, add the Ekvm library as a dependency in your dfx.json file:

mops install ekvm

Then, import Ekvm in your Motoko code:

import Ekvm "mo:ekvm/Ekvm";


Usage
Initializing the Store
First, create an instance of the Ekvm store:

db := EkvmModule.create(...);

Storing Data
To store a key-value pair:

EkvmModule.put(db, "key", "value");

Retrieving Data
To retrieve the value associated with a key:

EkvmModule.get(db, "key);
