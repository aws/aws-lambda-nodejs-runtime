// Resolves only through NODE_PATH, which ESM supports because of the ESM NODE_PATH patch.
import { fromLayer } from "layer-pkg";

export const handler = async () => ({ fromLayer });
