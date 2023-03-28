module main

import json
import note
import vweb

['/notes'; post]
fn (mut app App) create() vweb.Result {
    result := note.create(mut &app.db, app.req.data) or {
        return app.message_response(err)
    }

    app.created('/notes/${result.id}')

    return app.json(json.encode(result))
}

['/notes/:id'; get]
fn (mut app App) read(id int) vweb.Result {
    result := note.get(&app.db, id) or {
        return app.message_response(err)
    }

    return app.json(json.encode(result))
}

['/notes/'; get]
fn (mut app App) read_all() vweb.Result {
    result := note.get_all(&app.db) or {
        return app.message_response(err)
    }

    return app.json(json.encode(result))
}

['/notes/:id'; put]
fn (mut app App) update(id int) vweb.Result {
    result := note.update(mut &app.db, id, app.req.data) or {
        return app.message_response(err)
    }

    return app.json(json.encode(result))
}

['/notes/:id'; delete]
fn (mut app App) delete(id int) vweb.Result {
    result := note.delete(mut &app.db, id) or {
        return app.message_response(err)
    }
    return app.message_response(result)
}

