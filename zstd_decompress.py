import sys
import zstandard
import os

def decompress(data):
    dctx = zstandard.ZstdDecompressor()
    try:
        return dctx.decompress(data, max_output_size=len(data) * 200)
    except:
        import io
        reader = dctx.stream_reader(io.BytesIO(data))
        return reader.read()

if __name__ == "__main__":
    input_data = sys.stdin.buffer.read()
    debug_file = os.environ.get("ZSTD_DEBUG_FILE", "")
    try:
        result = decompress(input_data)
        sys.stdout.buffer.write(result)
        if debug_file:
            with open(debug_file, 'wb') as f:
                f.write(result)
            sys.stderr.write(f"DEBUG: decompressed {len(input_data)} -> {len(result)} bytes to {debug_file}\n")
    except Exception as e:
        sys.stderr.write(f"zstd error: {e}\n")
        sys.exit(1)
