import FluentKit
import FluentPostgresDriver
import Vapor

extension Application.Fluent {
  public var sessions: Sessions {
    .init(fluent: self)
  }

  public struct Sessions {
    let fluent: Application.Fluent
  }
}

public protocol ModelSessionAuthenticatable: Model, SessionAuthenticatable
where Self.SessionID == Self.IDValue {}

extension ModelSessionAuthenticatable {
  public var sessionID: SessionID {
    guard let id = self.id else {
      fatalError("Cannot persist unsaved model to session.")
    }
    return id
  }
}

extension Model where Self: SessionAuthenticatable, Self.SessionID == Self.IDValue {
  public static func sessionAuthenticator(
    _ databaseID: DatabaseID? = nil
  ) -> Authenticator {
    DatabaseSessionAuthenticator<Self>(databaseID: databaseID)
  }
}

extension Application.Fluent.Sessions {
  public func driver(_ databaseID: DatabaseID? = nil) -> SessionDriver {
    DatabaseSessions(databaseID: databaseID)
  }
}

extension Application.Sessions.Provider {
  public static var fluent: Self {
    return .fluent(nil)
  }

  public static func fluent(_ databaseID: DatabaseID?) -> Self {
    .init {
      $0.sessions.use { $0.fluent.sessions.driver(databaseID) }
    }
  }
}

private struct DatabaseSessions: SessionDriver {
  let databaseID: DatabaseID?

  init(databaseID: DatabaseID? = nil) {
    self.databaseID = databaseID
  }

  func createSession(_ data: SessionData, for request: Request) -> EventLoopFuture<SessionID> {
    let id = self.generateID()
    return SessionRecord(key: id, data: data)
      .create(on: request.db(self.databaseID))
      .map { id }
  }

  func readSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<SessionData?> {
    SessionRecord.query(on: request.db(self.databaseID))
      .filter(\.$key == sessionID)
      .first()
      .map { $0?.data }
  }

  func updateSession(_ sessionID: SessionID, to data: SessionData, for request: Request)
    -> EventLoopFuture<SessionID>
  {
    SessionRecord.query(on: request.db(self.databaseID))
      .filter(\.$key == sessionID)
      .set(\.$data, to: data)
      .update()
      .map { sessionID }
  }

  func deleteSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<Void> {
    SessionRecord.query(on: request.db(self.databaseID))
      .filter(\.$key == sessionID)
      .delete()
  }

  private func generateID() -> SessionID {
    var bytes = Data()
    for _ in 0..<32 {
      bytes.append(.random(in: .min ..< .max))
    }
    return .init(string: bytes.base64EncodedString())
  }
}

private struct DatabaseSessionAuthenticator<User>: SessionAuthenticator
where User: SessionAuthenticatable, User: Model, User.SessionID == User.IDValue {
  let databaseID: DatabaseID?

  func authenticate(sessionID: User.SessionID, for request: Request) -> EventLoopFuture<Void> {
    User.find(sessionID, on: request.db(self.databaseID)).map {
      if let user = $0 {
        request.auth.login(user)
      }
    }
  }
}
struct WebSessionMigrate: Migration {
  public init() {}

  public init(schema: String) {
    SessionRecord.schema = schema
  }

  func prepare(on database: Database) -> EventLoopFuture<Void> {
    return
      database.schema(SessionRecord.schema)
      .id()
      .field("key", .string, .required)
      .field("data", .json, .required)
      .field("clientip", .string)
      .field("created", .datetime, .required, .custom("DEFAULT now()"))
      .field("modified", .datetime, .required, .custom("DEFAULT now()"))
      .unique(on: "key")
      .create().flatMap {
        let sql = database as! SQLDatabase
        // Create the modified update function
        _ = sql.raw(
          SQLQueryString(
            "CREATE OR REPLACE FUNCTION update_modified_column() " + "RETURNS TRIGGER AS $$ "
              + "BEGIN " + "   IF row(NEW.*) IS DISTINCT FROM row(OLD.*) THEN "
              + "      NEW.modified = now(); " + "      RETURN NEW; " + "   ELSE "
              + "      RETURN OLD; " + "   END IF; " + "END; " + "$$ language 'plpgsql';")
        ).run()

        // Create the modified update trigger
        _ = sql.raw(
          SQLQueryString(
            "CREATE TRIGGER session_modified_timestamp_update " + "BEFORE UPDATE "
              + "ON websession " + "FOR EACH ROW " + "EXECUTE PROCEDURE update_modified_column();"
          )
        ).run()

        _ = sql.raw(
          SQLQueryString("COMMENT ON TABLE public.\"websession\" IS 'Active Web Session'.;")
        ).run()
        _ = sql.raw(
          SQLQueryString(
            "COMMENT ON COLUMN public.\"websession\".id IS 'Unique key for the record.';")
        ).run()
        _ = sql.raw(
          SQLQueryString(
            "COMMENT ON COLUMN public.\"websession\".key IS 'Unique identifier to the users session.';"
          )
        ).run()
        _ = sql.raw(
          SQLQueryString(
            "COMMENT ON COLUMN public.\"websession\".data IS 'Session specific data';")
        ).run()
        _ = sql.raw(
          SQLQueryString(
            "COMMENT ON COLUMN public.\"websession\".clientip IS 'Client''s IP address';")
        ).run()
        _ = sql.raw(
          SQLQueryString(
            "COMMENT ON COLUMN public.\"websession\".created IS 'When the session row was created';"
          )
        ).run()
        return sql.raw(
          SQLQueryString(
            "COMMENT ON COLUMN public.\"websession\".modified IS 'The last time the session row was updated';"
          )
        ).run()
      }
  }

  // Undo the change made in `prepare`, if possible.
  func revert(on database: Database) -> EventLoopFuture<Void> {
    return
      database.schema(SessionRecord.schema).delete()
  }
}
public final class SessionRecord: Model {
  public static var schema = "_fluent_sessions"

  // public static var migration: Migration {
  //   Create()
  // }

  @ID(key: .id)
  public var id: UUID?

  @Field(key: "key")
  public var key: SessionID

  @Field(key: "data")
  public var data: SessionData

  @OptionalField(key: "clientip")
  var clientip: String?

  @OptionalField(key: "created")
  var created: Date?

  @OptionalField(key: "modified")
  var modified: Date?

  public init() {}

  public init(id: UUID? = nil, key: SessionID, data: SessionData) {
    self.id = id
    self.key = key
    self.data = data
  }
}
