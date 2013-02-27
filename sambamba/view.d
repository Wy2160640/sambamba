/*
    This file is part of Sambamba.
    Copyright (C) 2012    Artem Tarasov <lomereiter@gmail.com>

    Sambamba is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Sambamba is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

*/
module sambamba.view;

import bio.bam.reader;
import bio.sam.reader;
import bio.core.region;

import sambamba.utils.view.filtering;
import sambamba.utils.view.alignmentrangeprocessor;
import sambamba.utils.view.headerserializer;
import sambamba.utils.view.queryparser;
import sambamba.utils.common.progressbar;

import bio.core.utils.format;

import std.stdio;
import std.c.stdio : stdout, freopen;
import std.string;
import std.array;
import std.traits;
import std.getopt;
import std.algorithm;

void printUsage() {
    stderr.writeln("Usage: sambamba-view [options] <input.bam | input.sam> [region1 [...]]");
    stderr.writeln();
    stderr.writeln("Options: -F, --filter=FILTER");
    stderr.writeln("                    set custom filter for alignments");
    stderr.writeln("         -f, --format=sam|bam|json");
    stderr.writeln("                    specify which format to use for output (default is SAM)");
    stderr.writeln("         -h, --with-header");
    stderr.writeln("                    print header before reads (always done for BAM output)");
    stderr.writeln("         -H, --header");
    stderr.writeln("                    output only header to stdout (if format=bam, the header is printed as SAM)");
    stderr.writeln("         -I, --reference-info");
    stderr.writeln("                    output to stdout only reference names and lengths in JSON");
    stderr.writeln("         -c, --count");
    stderr.writeln("                    output to stdout only count of matching records, hHI are ignored");
    stderr.writeln("         -v, --valid");
    stderr.writeln("                    output only valid alignments");
    stderr.writeln("         -S, --sam-input");
    stderr.writeln("                    specify that input is in SAM format");
    stderr.writeln("         -p, --show-progress");
    stderr.writeln("                    show progressbar in STDERR (works only for BAM files with no regions specified)");
    stderr.writeln("         -l, --compression-level");
    stderr.writeln("                    specify compression level (from 0 to 9, works only for BAM output)");
    stderr.writeln("         -o, --output-filename");
    stderr.writeln("                    specify output filename");
}

void outputReferenceInfoJson(T)(T bam) {
    
    putcharacter(stdout, '[');

    bool first = true;
    foreach (refseq; bam.reference_sequences) {
        if (first) {
            first = false;
        } else {
            putcharacter(stdout, ',');
        }
        putstring(stdout, `{"name":"`);
        foreach (char c; refseq.name) {
            if (c == '\\' || c == '"')
                putcharacter(stdout, '\\');
            putcharacter(stdout, c);
        }
        putstring(stdout, `","length":`);
        putinteger(stdout, refseq.length);
        putcharacter(stdout, '}');
    }

    putcharacter(stdout, ']');
    putcharacter(stdout, '\n');
}

string format = "sam";
string query;
bool with_header;
bool header_only;
bool reference_info_only;
bool count_only;
bool skip_invalid_alignments;
bool is_sam;

bool show_progress;

int compression_level = -1;
string output_filename;

version(standalone) {
    int main(string[] args) {
        return view_main(args);
    }
}

int view_main(string[] args) {
    try {

        getopt(args,
               std.getopt.config.caseSensitive,
               "filter|F",            &query,
               "format|f",            &format,
               "with-header|h",       &with_header,
               "header|H",            &header_only,
               "reference-info|I",    &reference_info_only,
               "count|c",             &count_only,
               "valid|v",             &skip_invalid_alignments,
               "sam-input|S",         &is_sam,
               "show-progress|p",     &show_progress,
               "compression-level|l", &compression_level,
               "output-filename|o",   &output_filename);
        
        if (args.length < 2) {
            printUsage();
            return 0;
        }

        if (!is_sam) {
            auto bam = new BamReader(args[1]); 
            return sambambaMain(bam, args);
        } else {
            auto sam = new SamReader(args[1]);
            return sambambaMain(sam, args);
        }
    } catch (Exception e) {
        stderr.writeln("sambamba-view: ", e.msg);

        version(development) {
            throw e; // rethrow to see detailed message
        }

        return 1;
    }
}

// TODO: mark pure functions/methods with 'pure' attribute
//       so that it becomes visible that accepts() is pure.
static __gshared Filter filter; 

bool passing(BamRead read) {
    return filter.accepts(read);
}

auto filtered(R)(R reads) {
    return std.algorithm.filter!passing(reads);
}

// In fact, $(D bam) is either BAM or SAM file
int sambambaMain(T)(T _bam, string[] args) 
    if (is(T == SamReader) || is(T == BamReader)) 
{

    auto bam = _bam; // FIXME: uhm, that was a workaround for some closure-related bug

    if (reference_info_only && !count_only) {
        outputReferenceInfoJson(bam);
        return 0;
    }

    if (header_only && !count_only) {
        // write header to stdout
        (new HeaderSerializer(format)).writeln(bam.header);
    } else if (with_header && !count_only && format != "bam") {
        // for BAM, header will be written by writeBAM function
        if (output_filename !is null) {
            freopen(toStringz(output_filename), "w+", std.c.stdio.stdout);
        }
        (new HeaderSerializer(format)).writeln(bam.header);
    }
    
    if (header_only) return 0;

    filter = new NullFilter();

    if (skip_invalid_alignments) {
        filter = new AndFilter(filter, new ValidAlignmentFilter());
    }

    if (query !is null) {
        auto query_grammar = new QueryGrammar();
        auto node = query_grammar.parse(query);
        auto condition_node = cast(ConditionNode) node;
        if (condition_node is null) {
            stderr.writeln("filter string must represent a condition");
            return 1;
        }
        filter = new AndFilter(filter, condition_node.condition);
    }

    int processAlignments(AlignmentRangeProcessor)(AlignmentRangeProcessor processor) {
        static if (is(T == SamReader)) {
            if (args.length > 2) {
                stderr.writeln("sorry, accessing regions is unavailable for SAM input");
                return 1;
            }
        }

        if (args.length == 2) {
            
            static if (is(T == BamReader)) {
                if (show_progress) {
                    auto bar = new shared(ProgressBar)();
                    auto reads = bam.readsWithProgress((lazy float p) { bar.update(p); });
                    processor.process(filtered(reads), bam);
                    bar.finish();
                } else {
                    processor.process(filtered(bam.reads!withoutOffsets), bam);
                }
            } else { // SamFile
                processor.process(filtered(bam.reads), bam);
            }
        } 

        // for BAM, random access is available
        static if (is(T == BamReader)) {
            if (args.length > 2) {
                auto regions = map!parseRegion(args[2 .. $]);

                alias ReturnType!(ReferenceSequence.opSlice) AlignmentRange;
                auto alignment_ranges = new AlignmentRange[regions.length];

                size_t i = 0;
                foreach (ref r; regions) {
                    alignment_ranges[i++] = bam[r.reference][r.beg .. r.end];
                }

                auto reads = joiner(alignment_ranges);
                processor.process(filtered(reads), bam);
            }
        }

        return 0;
    }

    if (count_only) {
        auto counter = new ReadCounter();

        if (processAlignments(counter))
            return 1;
        writeln(counter.number_of_reads);
    } else {
        bool append_to_existing_file = with_header; // header is written already? (unless output format is BAM)
        switch (format) {
            case "bam":
                return processAlignments(new BamSerializer(output_filename, compression_level));
            case "sam":
                return processAlignments(new SamSerializer(output_filename, append_to_existing_file));
            case "json":
                return processAlignments(new JsonSerializer(output_filename, append_to_existing_file));
            case "msgpack":
                return processAlignments(new MsgpackSerializer(output_filename, append_to_existing_file));
            default:
                stderr.writeln("output format must be one of sam, bam, json");
                return 1;
        }
    }

    return 0;
}