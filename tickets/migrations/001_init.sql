CREATE TABLE events (
    id                bigserial PRIMARY KEY,
    title             varchar(100) NOT NULL,
    capacity          integer NOT NULL CHECK (capacity >= 0),
    tickets_available integer NOT NULL CHECK (tickets_available >= 0),
    CHECK (tickets_available <= capacity)
);

CREATE TYPE reservation_status AS ENUM ('HELD', 'CONFIRMED', 'RELEASED');

CREATE TABLE reservations (
    order_id   bigint PRIMARY KEY,
    event_id   bigint NOT NULL REFERENCES events (id),
    quantity   integer NOT NULL CHECK (quantity > 0),
    status     reservation_status NOT NULL,
    expires_at timestamptz NOT NULL
);
