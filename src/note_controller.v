module main

import json
import notes
import vweb

['/notes'; post]
fn (mut app App) create() vweb.Result {
    result := notes.create(mut &app.db, app.req.data) or {
        return app.message_response(err)
    }

    app.created('/notes/${result.id}')

    return app.json(json.encode(result))
}

['/notes/:id'; get]
fn (mut app App) read(id int) vweb.Result {
    result := notes.get(&app.db, id) or {
        return app.message_response(err)
    }

    return app.json(json.encode(result))
}

['/notes/'; get]
fn (mut app App) read_all() vweb.Result {
    result := notes.get_all(&app.db) or {
        return app.message_response(err)
    }

    return app.json(json.encode(result))
}

['/notes/:id'; put]
fn (mut app App) update(id int) vweb.Result {
    result := notes.update(mut &app.db, id, app.req.data) or {
        return app.message_response(err)
    }

    return app.json(json.encode(result))
}

['/notes/:id'; delete]
fn (mut app App) delete(id int) vweb.Result {
    result := notes.delete(mut &app.db, id) or {
        return app.message_response(err)
    }
    return app.message_response(result)
}

