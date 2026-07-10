const fs = require("fs").promises;

const deobfuscate = async (inputPath, outputPath) => {
    const src = (await fs.readFile(inputPath)).toString();

    let output = src;

    output = output.replace(/--\[\[.*?\]\]/gs, "");

    const stringTableMatch = output.match(/local\s+Q\s*=\s*\{([^}]*)\}/s);
    if (!stringTableMatch) {
        output = output.replace(/\\(\d{3})/g, (_, dec) => String.fromCharCode(parseInt(dec, 10)));
        await fs.writeFile(outputPath, output);
        return;
    }

    const rawStrings = stringTableMatch[1];
    const strings = [];
    const stringRegex = /"((?:\\.|[^"\\])*)"/g;
    let m;
    while ((m = stringRegex.exec(rawStrings)) !== null) {
        let s = m[1];
        s = s.replace(/\\(\d{3})/g, (_, dec) => String.fromCharCode(parseInt(dec, 10)));
        s = s.replace(/\\n/g, "\n").replace(/\\r/g, "\r").replace(/\\t/g, "\t").replace(/\\\\/g, "\\").replace(/\\"/g, '"');
        strings.push(s);
    }

    let deobfuscated = "-- WeAreDevs Deobfuscated\n\n";

    const envMatch = output.match(/getfenv\s*(?:and\s*getfenv\(\)\s*or\s*_ENV)/);
    if (envMatch) {
        deobfuscated += "local Env = getfenv()\n";
    }

    const unpackMatch = output.match(/unpack\s*or\s*table\[([^\]]+)\]/);
    if (unpackMatch) {
        deobfuscated += "local unpack = unpack or table.unpack\n";
    }

    const proxyMatch = output.match(/newproxy/);
    if (proxyMatch) {
        deobfuscated += "local newproxy = newproxy\n";
    }

    const setmetaMatch = output.match(/setmetatable/);
    if (setmetaMatch) {
        deobfuscated += "local setmetatable = setmetatable\n";
    }

    const getmetaMatch = output.match(/getmetatable/);
    if (getmetaMatch) {
        deobfuscated += "local getmetatable = getmetatable\n";
    }

    const selectMatch = output.match(/select/);
    if (selectMatch) {
        deobfuscated += "local select = select\n";
    }

    deobfuscated += "\n";

    deobfuscated += "-- Decoded string table (" + strings.length + " entries):\n";
    for (let i = 0; i < strings.length; i++) {
        const safe = strings[i].replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r");
        deobfuscated += `-- [${i}] = "${safe}"\n`;
    }

    deobfuscated += "\n-- Original obfuscated code:\n";

    let cleanedCode = output;

    cleanedCode = cleanedCode.replace(/\\(\d{3})/g, (_, dec) => {
        const ch = String.fromCharCode(parseInt(dec, 10));
        if (ch === '"' || ch === "\\" || ch === "\n") return "\\" + ch;
        return ch;
    });

    deobfuscated += cleanedCode + "\n";

    await fs.writeFile(outputPath, deobfuscated);
};

deobfuscate(process.argv[2], process.argv[3]).catch(err => {
    console.error("Deobfuscation failed:", err.message || err);
    process.exit(1);
});
