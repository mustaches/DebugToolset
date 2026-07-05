import json
import sys

log_file = r'C:\Users\20763\.gemini\antigravity-ide\brain\59ea0684-de6c-4d94-8aac-7bbf307a0a83\.system_generated\logs\transcript.jsonl'
output_file = 'i2c_ui_recovery.txt'

with open(log_file, 'r', encoding='utf-8') as f, open(output_file, 'w', encoding='utf-8') as out:
    for line in f:
        try:
            data = json.loads(line)
            if 'tool_calls' in data:
                for call in data['tool_calls']:
                    if call['function']['name'] in ['multi_replace_file_content', 'replace_file_content', 'run_command']:
                        args = call['function']['arguments']
                        if 'ReplacementContent' in args:
                            out.write(args['ReplacementContent'] + '\n\n' + '='*80 + '\n\n')
                        elif 'ReplacementChunks' in args:
                            for chunk in args['ReplacementChunks']:
                                out.write(chunk['ReplacementContent'] + '\n\n' + '='*80 + '\n\n')
                        elif 'CommandLine' in args:
                            out.write(args['CommandLine'] + '\n\n' + '='*80 + '\n\n')
        except Exception as e:
            pass
