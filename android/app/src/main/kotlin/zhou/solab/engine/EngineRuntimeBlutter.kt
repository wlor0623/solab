package zhou.solab.engine

import org.json.JSONObject

internal fun EngineRuntime.flutterBlutter(args: JSONObject): JSONObject = guarded { blutter.handle(args, workDir) }
