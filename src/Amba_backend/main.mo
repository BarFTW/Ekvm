import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Nat "mo:base/Nat";

shared({caller}) actor class Amba() = this {

  public type Agent = {
    name: Text;
    id: Principal;
    uuid: Text;
  };

  public type Project = {
    name: Text;
    id: Principal;
    uuid: Text;
  };

  public type Campaign = {
    name: Text;
    id: Principal;
    uuid: Text;
  };

  private var agents : HashMap.HashMap<Nat, Agent> = HashMap.HashMap<Nat, Agent>(10);
  private var projects = {};
  private var campaigns = {};
  private var dealOffers = {};
  private var deals = {};  
};
