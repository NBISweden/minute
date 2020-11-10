import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from io import StringIO
from itertools import groupby
from typing import List

from xopen import xopen


class ParseError(Exception):
    pass


@dataclass
class Library:
    sample: str


@dataclass
class FastqLibrary(Library):
    replicate: str
    barcode: str
    fastqbase: str

    @property
    def name(self):
        return f"{self.sample}_rep{self.replicate}"


@dataclass
class PooledLibrary(Library):
    replicates: List[FastqLibrary]

    @property
    def name(self):
        return f"{self.sample}_pooled"


@dataclass
class TreatmentControlPair:
    treatment: Library
    control: Library


@dataclass
class ScalingGroup:
    normalization_pairs: List[TreatmentControlPair]
    name: str


def read_libraries():
    for row in read_tsv("libraries.tsv", columns=4):
        yield FastqLibrary(*row)


def group_libraries_by_sample(libraries):
    samples = defaultdict(list)
    for library in libraries:
        samples[library.sample].append(library)
    for sample, replicates in samples.items():
        yield PooledLibrary(sample=sample, replicates=replicates)


def read_scaling_groups(libraries):
    library_map = {
        (library.sample, library.replicate): library for library in libraries}

    pools = group_libraries_by_sample(libraries)
    for pool in pools:
        library_map[(pool.sample, "pooled")] = pool

    scaling_map = defaultdict(list)
    for row in read_tsv("groups.tsv", columns=4):
        treatment = library_map[(row[0], row[1])]
        control = library_map[(row[2], row[1])]
        scaling_map[row[3]].append(TreatmentControlPair(treatment, control))

    for name, normalization_pairs in scaling_map.items():
        yield ScalingGroup(normalization_pairs, name)


def read_tsv(path, columns: int):
    """
    Read a tab-separated value file from path, allowing "#"-prefixed comments

    Yield a list of fields for every row (ignoring comments and empty lines)

    If the number of fields in a row does not match *columns*, a ParseError
    is raised.
    """
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#") or not line:
                continue
            fields = line.strip().split("\t")
            if len(fields) != columns:
                raise ParseError(
                    f"Expected {columns} tab-separated fields in {path}, but found {len(fields)}")
            yield fields


def flagstat_mapped_reads(path):
    """Read "samtools flagstat" output and return the number of mapped reads"""
    with open(path) as f:
        for line in f:
            if " mapped (" in line:
                return int(line.split(maxsplit=1)[0])


def parse_insert_size_metrics(path):
    return parse_picard_metrics(path, metrics_class="picard.analysis.InsertSizeMetrics")


def parse_duplication_metrics(path):
    return parse_picard_metrics(path, metrics_class="picard.sam.DuplicationMetrics")


def parse_picard_metrics(path, metrics_class: str):
    """
    Parse the METRICS section in a metrics file created by Picard. The string
    given after 'METRICS CLASS' in the file must match the metrics_class
    parameter. Anything else in the file is not parsed.

    Return a dictionary that has keys such as "median_insert_size",
    "estimated_library_size" etc. (this depends on the headers in the file).
    """
    def float_or_int(s):
        try:
            return int(s)
        except ValueError:
            try:
                return float(s)
            except ValueError:
                return s

    with open(path) as f:
        for line in f:
            if line.startswith("## METRICS CLASS"):
                fields = line.strip().split(sep="\t")
                if fields[1] != metrics_class:
                    raise ParseError(
                        "While parsing Picard metrics file '{}':"
                        "Expected metrics class {}, but found {}".format(
                            path, metrics_class, fields[1]))
                break
        header = next(f).strip().split("\t")
        values = next(f).strip().split("\t")

    # Picard issue: it leaves library size blank sometimes, I think for small
    # sample sizes. 
    if len(values) == len(header) - 1:
        values.append('NA')

    result = {key.lower(): float_or_int(value) for key, value in zip(header, values)}
    return result


def compute_scaling(scaling_group, treatments, controls, infofile, genome_size, fragment_size):
    first = True
    scaling_factor = -1
    for pair, treatment_path, control_path in zip(scaling_group.normalization_pairs, treatments, controls):
        treatment_reads = flagstat_mapped_reads(treatment_path)
        control_reads = flagstat_mapped_reads(control_path)
        if first:
            scaling_factor = (
                genome_size / fragment_size / treatment_reads * control_reads
            )
            treatment_reads_ref = treatment_reads
            control_reads_ref = control_reads
            first = False

        sample_scaling_factor = scaling_factor / control_reads
        scaled_treatment_reads = sample_scaling_factor * treatment_reads

        # TODO factor this out
        print(pair.treatment.name, treatment_reads, scaled_treatment_reads, pair.control.name, control_reads, sample_scaling_factor, scaling_group.name, sep="\t", file=infofile)

        # TODO scaled.idxstats.txt file

        yield sample_scaling_factor


def parse_stats_fields(stats_file):
    """
    Parse contents of a stats file created in the stats rule, which consists
    of a header line and a values line.

    Return a dictionary where keys are defined by the values of the header.
    """
    with open(stats_file) as f:
        header = f.readline().strip().split("\t")
        values = f.readline().strip().split("\t")
        result = {key.lower(): value for key, value in zip(header, values)}
        result["library"] = Path(stats_file).stem
        return result


def read_int_from_file(path):
    with open(path) as f:
        data = f.read()
    return int(data.strip())


def compute_genome_size(fasta):
    n = 0
    with xopen(fasta) as f:
        for line in f:
            if line[:1] != ">":
                line = line.rstrip().upper()
                n += len(line) - line.count("N")
    return n


def detect_bowtie_index_name(fasta_path):
    """
    Given the path to a reference FASTA (which may optionally be compressed),
    detect the base name of the Bowtie2 index assumed to be in the same
    location.

    Given "ref.fasta.gz", this function checks for the existence of
    - "ref.fasta.gz.1.bt2"
    - "ref.fasta.1.bt2"
    - "ref.1.bt2"
    in that order and then returns the name of the first file it finds
    minus the ".1.bt2" suffix.
    """
    path = Path(fasta_path)
    bowtie_index_extension = ".1.bt2"
    bases = [path]
    if path.suffix == ".gz":
        bases.append(path.with_suffix(""))
    if bases[-1].suffix:
        bases.append(bases[-1].with_suffix(""))
    for base in bases:
        if base.with_name(base.name + bowtie_index_extension).exists():
            return base
    raise FileNotFoundError(
        "No Bowtie2 index found, expected one of\n- "
        + "\n- ".join(str(b) + bowtie_index_extension for b in bases)
    )


def get_replicates(libraries, sample):
    replicates = [lib.replicate for lib in libraries if lib.sample == sample]
    return replicates


def get_normalization_pairs(scaling_groups) -> List[TreatmentControlPair]:
    return [pair for group in scaling_groups for pair in group.normalization_pairs]


def format_metadata_overview(libraries, pools, scaling_groups) -> str:
    f = StringIO()
    print("# Libraries", file=f)
    for library in libraries:
        print(" -", library, file=f)

    print(file=f)
    print("# Pools", file=f)
    for pool in pools:
        print(" -", pool.name, "(replicates:", ", ".join(r.replicate for r in pool.replicates) + ")", file=f)

    print(file=f)
    print("# Scaling groups", file=f)

    for group in scaling_groups:
        print("# Group", group.name, "- Normalization Pairs (treatment -- control)", file=f)
        for pair in group.normalization_pairs:
            print(" -", pair.treatment.name, "--", pair.control.name, file=f)
    return f.getvalue()


def is_snakemake_calling_itself():
    return "snakemake/__main__.py" in sys.argv[0]


def map_fastq_prefix_to_list_of_libraries(libraries: List[Library]):
    return {
        fastq_base: list(libs)
        for fastq_base, libs in
        groupby(sorted(libraries, key=lambda lib: lib.fastqbase), key=lambda lib: lib.fastqbase)
    }
