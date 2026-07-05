import os
import io
import asyncio
import tempfile
import subprocess

import discord
from discord.ext import commands
from dotenv import load_dotenv

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN")
LUNE_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catlog.luau")
LUNE_BIN = os.getenv("LUNE_BIN", "lune")
TIMEOUT_SECONDS = 30

intents = discord.Intents.default()
intents.message_content = True

bot = commands.Bot(command_prefix=".", intents=intents, help_command=None)


async def extract_code(ctx: commands.Context, content: str) -> str | None:
    if ctx.message.attachments:
        att = ctx.message.attachments[0]
        data = await att.read()
        return data.decode("utf-8", errors="ignore")

    if ctx.message.reference:
        try:
            ref_msg = await ctx.channel.fetch_message(ctx.message.reference.message_id)
        except discord.NotFound:
            ref_msg = None
        if ref_msg:
            if ref_msg.attachments:
                data = await ref_msg.attachments[0].read()
                return data.decode("utf-8", errors="ignore")
            if ref_msg.content:
                content = ref_msg.content + "\n" + content

    if "```" in content:
        parts = content.split("```")
        if len(parts) >= 2:
            block = parts[1]
            first_line, _, rest = block.partition("\n")
            if first_line.strip().isalpha():
                return rest
            return block

    return None


def run_lune(code: str) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory() as tmp:
        input_path = os.path.join(tmp, "input.lua")
        output_path = os.path.join(tmp, "out.lua")

        with open(input_path, "w", encoding="utf-8") as f:
            f.write(code)

        cmd = [
            LUNE_BIN,
            "run",
            LUNE_SCRIPT,
            "--",
            input_path,
            f"out={output_path}",
        ]

        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_SECONDS,
                cwd=tmp,
            )
        except FileNotFoundError:
            return False, "Could not find the lune executable. Set LUNE_BIN in your .env."
        except subprocess.TimeoutExpired:
            return False, "exceeded the time limit."

        if proc.returncode != 0 and not os.path.exists(output_path):
            err = (proc.stderr or proc.stdout or "Unknown error").strip()
            return False, err[:1900]

        if os.path.exists(output_path):
            with open(output_path, "r", encoding="utf-8", errors="ignore") as f:
                return True, f.read()

        return False, (proc.stdout or "No output.").strip()[:1900]


@bot.command(name="l")
async def analyze(ctx: commands.Context, *, text: str = ""):
    code = await extract_code(ctx, text)

    if not code or not code.strip():
        await ctx.reply(
            "Attach a .lua/.luau file, reply to a message that has one, "
            "or put the code in a ```lua ... ``` code block."
        )
        return

    async with ctx.typing():
        loop = asyncio.get_running_loop()
        ok, result = await loop.run_in_executor(None, run_lune, code)

    if not ok:
        await ctx.reply(f"Error:\n```\n{result}\n```")
        return

    if len(result) > 1900:
        file = discord.File(io.BytesIO(result.encode("utf-8")), filename="result.lua")
        await ctx.reply("done, attached file:", file=file)
    else:
        await ctx.reply(f"Result:\n```lua\n{result}\n```")


@bot.event
async def on_ready():
    print(f"Logged in as {bot.user} (ID: {bot.user.id})")


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("Missing DISCORD_TOKEN in the .env file")
    bot.run(TOKEN)
