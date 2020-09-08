import se_bam
# TODO
# - switch to interleaved files?
from itertools import groupby
from pathlib import Path
from utils import (
    read_libraries,
    read_controls,
    flagstat_mapped_reads,
    compute_scaling,
    parse_duplication_metrics,
    parse_insert_size_metrics,
    parse_stats_fields,
    read_int_from_file,
    compute_genome_size,
    detect_bowtie_index_name,
    get_replicates,
    group_pools,
)


configfile: "config.yaml"

if "bowtie_index_name" not in config:
    try:
        config["bowtie_index_name"] = detect_bowtie_index_name(config["reference_fasta"])
    except FileNotFoundError as e:
        sys.exit(str(e))


libraries = list(read_libraries())
pools = list(group_pools(libraries))
normalization_pairs = list(read_controls(libraries + pools))  # or: normalization_groups


# Map a FASTQ prefix to its list of libraries
fastq_map = {
    fastq_base: list(libs)
    for fastq_base, libs in
    groupby(sorted(libraries, key=lambda lib: lib.fastqbase), key=lambda lib: lib.fastqbase)
}


rule multiqc:
    output: "multiqc_report.html"
    input:
        expand([
            "igv/{library.name}.bw",
            "stats/{library.name}.txt",
            "igv/{library.sample}_pooled.bw",
            "stats/{library.sample}_pooled.txt",
        ], library=libraries),
        expand("fastqc/{fastq}_R{read}_fastqc.html",
            fastq=fastq_map.keys(), read=(1, 2)),
        expand("scaled/{library.name}.scaled.bw",
            library=[np.treatment for np in normalization_pairs]),
        "summaries/stats_summary.txt",
    shell:
        "multiqc ."


rule clean:
    shell:
        "rm -rf"
        " tmp"
        " results"
        " restricted"
        " igv"
        " fastqc"
        " scaled"
        " stats"
        " summaries"
        " log"
        " multiqc_report.html"
        " multiqc_data"


rule fastqc_input:
    output:
        "fastqc/{name}_fastqc.html"
    input:
        fastq="fastq/{name}.fastq.gz"
    shell:
        "fastqc -o fastqc {input.fastq}"
        " && rm fastqc/{wildcards.name}_fastqc.zip"


rule move_umi_to_header:
    output:
        r1=temp("tmp/noumi/{name}.1.fastq.gz"),
        r2=temp("tmp/noumi/{name}.2.fastq.gz"),
    input:
        r1="fastq/{name}_R1.fastq.gz",
        r2="fastq/{name}_R2.fastq.gz",
    params:
        umistring="N" * config['umi_length']
    shell:
        "umi_tools "
        " extract"
        " --extract-method=string"
        " -p {params.umistring}"
        " -I {input.r1}"
        " --read2-in={input.r2}"
        " -S {output.r1}"
        " --read2-out {output.r2}"


rule remove_contamination:
    threads:
        8
    output:
        r1=temp("tmp/noadapters/{name}.1.fastq.gz"),
        r2=temp("tmp/noadapters/{name}.2.fastq.gz"),
    input:
        r1="tmp/noumi/{name}.1.fastq.gz",
        r2="tmp/noumi/{name}.2.fastq.gz",
    log:
        "tmp/noadapters/{name}.trimmed.log"
    shell:
        "cutadapt"
        " -j {threads}"
        " -e 0.15"
        " -A TTTTTCTTTTCTTTTTTCTTTTCCTTCCTTCTAA"
        " --discard-trimmed"
        " -o {output.r1}"
        " -p {output.r2}"
        " {input.r1}"
        " {input.r2}"
        " > {log}"


rule barcodes:
    """File with list of barcodes needed for demultiplexing"""
    output:
        barcodes_fasta=temp("tmp/barcodes/{fastqbase}.fasta")
    run:
        with open(output.barcodes_fasta, "w") as f:
            for library in libraries:
                if library.fastqbase != wildcards.fastqbase:
                    continue
                f.write(f">{library.name}\n^{library.barcode}\n")


for fastq_base, libs in fastq_map.items():

    rule:
        output:
            temp(expand("tmp/demultiplexed/{library.name}_R{read}.fastq.gz", library=libs, read=(1, 2))),
            unknown_r1=temp("tmp/demultiplexed/{fastqbase}-unknown_R1.fastq.gz".format(fastqbase=fastq_base)),
            unknown_r2=temp("tmp/demultiplexed/{fastqbase}-unknown_R2.fastq.gz".format(fastqbase=fastq_base)),
        input:
            r1="tmp/noadapters/{fastqbase}.1.fastq.gz".format(fastqbase=fastq_base),
            r2="tmp/noadapters/{fastqbase}.2.fastq.gz".format(fastqbase=fastq_base),
            barcodes_fasta="tmp/barcodes/{fastqbase}.fasta".format(fastqbase=fastq_base),
        params:
            r1=lambda wildcards: "tmp/demultiplexed/{name}_R1.fastq.gz",
            r2=lambda wildcards: "tmp/demultiplexed/{name}_R2.fastq.gz",
            fastqbase=fastq_base,
        log:
            "log/demultiplexed/{fastqbase}.log".format(fastqbase=fastq_base)
        shell:
            "cutadapt"
            " -e 0.15"  # TODO determine from barcode length
            " -g file:{input.barcodes_fasta}"
            " -o {params.r1}"
            " -p {params.r2}"
            " --untrimmed-output tmp/demultiplexed/{params.fastqbase}-unknown_R1.fastq.gz"
            " --untrimmed-paired-output tmp/demultiplexed/{params.fastqbase}-unknown_R2.fastq.gz"
            " {input.r1}"
            " {input.r2}"
            " > {log}"


def set_demultiplex_rule_names():
    """
    This sets the names of the demultiplexing rules, which need to be
    defined anonymously because they are defined (above) in a loop.
    """
    prefix = "tmp/noadapters/"
    for rul in workflow.rules:
        if not "barcodes_fasta" in rul.input.keys():
            # Ensure we get the demultiplexing rules only
            continue
        input = rul.input["r1"]
        assert input.startswith(prefix)
        # Remove the prefix and the ".1.fastq.gz" suffix
        rul.name = "demultiplex_" + rul.input["r1"][len(prefix):-11]


set_demultiplex_rule_names()


rule bowtie2:
    threads:
        20
    output:
        bam=temp("tmp/mapped/{sample}_replicate{replicate}.bam")
    input:
        r1="tmp/demultiplexed/{sample}_replicate{replicate}_R1.fastq.gz",
        r2="tmp/demultiplexed/{sample}_replicate{replicate}_R2.fastq.gz",
    log:
        "log/bowtie2-{sample}_replicate{replicate}.log"
    # TODO
    # - --sensitive (instead of --fast) would be default
    # - write uncompressed BAM?
    # - filter unmapped reads directly? (samtools view -F 4 or bowtie2 --no-unal)
    # - add RG header
    shell:
        "bowtie2"
        " -p {threads}"
        " -x {config[bowtie_index_name]}"
        " -1 {input.r1}"
        " -2 {input.r2}"
        " --fast"
        " 2> {log}"
        " "
        "| samtools sort -o {output.bam} -"


rule pool_replicates:
    output:
        bam=temp("tmp/mapped/{sample}_pooled.bam")
    input:
        bam_replicates=lambda wildcards: expand(
            "tmp/mapped/{{sample}}_replicate{replicates}.bam",
            replicates=get_replicates(libraries, wildcards.sample))
    run:
        if len(input.bam_replicates) == 1:
            os.link(input.bam_replicates[0], output.bam)
        else:
            # samtools merge output is already sorted
            shell("samtools merge {output.bam} {input.bam_replicates}")


rule convert_to_single_end:
    """Convert sam files to single-end for marking duplicates"""
    output:
        bam=temp("tmp/mapped_se/{library}.bam")
    input:
        bam="tmp/mapped/{library}.bam"
    run:
        se_bam.convert_paired_end_to_single_end_bam(
            input.bam,
            output.bam,
            keep_unmapped=False)

# TODO have a look at UMI-tools also
rule mark_duplicates:
    """UMI-aware duplicate marking with je suite"""
    output:
        bam=temp("tmp/dupmarked/{library}.bam"),
        metrics="tmp/dupmarked/{library}.metrics"
    input:
        bam="tmp/mapped_se/{library}.bam"
    shell:
        "LC_ALL=C je"
        " markdupes"
        " MISMATCHES=1"
        " REMOVE_DUPLICATES=FALSE"
        " SLOTS=-1"
        " SPLIT_CHAR=_"
        " I={input.bam}"
        " O={output.bam}"
        " M={output.metrics}"


rule mark_pe_duplicates:
    """Select duplicate-flagged alignments and mark them in the PE file"""
    output:
        bam=temp("tmp/dedup/{library}.bam")
    input:
        target_bam="tmp/mapped/{library}.bam",
        proxy_bam="tmp/dupmarked/{library}.bam"
    run:
        se_bam.mark_duplicates_by_proxy_bam(
            input.target_bam,
            input.proxy_bam,
            output.bam)


rule remove_exclude_regions:
    output:
        bam="restricted/{library}.bam"
    input:
        bam="tmp/dedup/{library}.bam",
        bed=config["exclude_regions"]
    shell:
        "bedtools"
        " intersect"
        " -v"
        " -abam {input.bam}"
        " -b {input.bed}"
        " > {output.bam}"


rule insert_size_metrics:
    output:
        txt="restricted/{library}.insertsizes.txt",
        pdf="restricted/{library}.insertsizes.pdf",
    input:
        bam="restricted/{library}.bam"
    shell:
        "picard"
        " CollectInsertSizeMetrics"
        " I={input.bam}"
        " O={output.txt}"
        " HISTOGRAM_FILE={output.pdf}"
        " MINIMUM_PCT=0.5"
        " STOP_AFTER=10000000"


rule bigwig:
    output:
        bw="igv/{library}.bw"
    input:
        bam="restricted/{library}.bam",
        bai="restricted/{library}.bai",
        genome_size="genome_size.txt",
    threads: 20
    shell:
        "bamCoverage"
        " -p {threads}"
        " --normalizeUsing RPGC"
        " --effectiveGenomeSize $(< {input.genome_size})"
        " -b {input.bam}"
        " -o {output.bw}"
        " --binSize 1"


rule compute_scaling_factors:
    input:
        treatments=["restricted/{library.name}.flagstat.txt".format(library=np.treatment) for np in normalization_pairs],
        controls=["restricted/{library.name}.flagstat.txt".format(library=np.control) for np in normalization_pairs],
        genome_size="genome_size.txt",
    output:
        factors=temp(["tmp/factors/{library.name}.factor.txt".format(library=np.treatment) for np in normalization_pairs]),
        info="summaries/scalinginfo.txt"
    run:
        with open(output.info, "w") as outf:
            factors = compute_scaling(
                normalization_pairs,
                input.treatments,
                input.controls,
                outf,
                genome_size=read_int_from_file(input.genome_size),
                fragment_size=config["fragment_size"],
            )
            for factor, factor_path in zip(factors, output.factors):
                with open(factor_path, "w") as f:
                    print(factor, file=f)

rule extract_fragment_size:
    input:
        insertsizes="restricted/{library}.insertsizes.txt"
    output:
        fragsize="restricted/{library}.fragsize.txt"
    run:
        with open(output.fragsize, "w") as f:
            print(int(parse_insert_size_metrics(input.insertsizes)["median_insert_size"]),
                  file=f)


rule scaled_bigwig:
    output:
        bw="scaled/{library}.scaled.bw"
    input:
        factor="tmp/factors/{library}.factor.txt",
        fragsize="restricted/{library}.fragsize.txt",
        bam="restricted/{library}.bam",
        bai="restricted/{library}.bai",
    threads: 20
    shell:
        # TODO also run this
        # - with "--binSize 50 --smoothLength 150"
        # - with "--binSize 500 --smoothLength 5000"
        "bamCoverage"
        " -p {threads}"
        " --binSize 1"
        " --extendReads $(< {input.fragsize})"
        " --scaleFactor $(< {input.factor})"
        " --bam {input.bam}"
        " -o {output.bw}"


rule stats:
    output:
        txt="stats/{library}.txt"
    input:
        mapped="tmp/mapped/{library}.flagstat.txt",
        dedup="tmp/dedup/{library}.flagstat.txt",
        restricted="restricted/{library}.flagstat.txt",
        metrics="tmp/dupmarked/{library}.metrics",
        insertsizes="restricted/{library}.insertsizes.txt",
    run:
        row = []
        for flagstat, name in [
            (input.mapped, "mapped"),
            (input.dedup, "dedup"),
            (input.restricted, "restricted"),
        ]:
            mapped_reads = flagstat_mapped_reads(flagstat)
            row.append(mapped_reads)

        row.append(parse_duplication_metrics(input.metrics)["estimated_library_size"])
        row.append(parse_duplication_metrics(input.metrics)["percent_duplication"])
        row.append(parse_insert_size_metrics(input.insertsizes)["median_insert_size"])
        with open(output.txt, "w") as f:
            print("mapped", "dedup_mapped", "restricted_mapped", "library_size", "percent_duplication", "insert_size", sep="\t", file=f)
            print(*row, sep="\t", file=f)


rule stats_summary:
    output:
        txt="summaries/stats_summary.txt"
    input:
        expand("stats/{library.name}.txt", library=libraries) + expand("stats/{pool.name}.txt", pool=pools)
    run:
        stats_summaries = [parse_stats_fields(st_file) for st_file in input]

        # I am considering we want the keys to be in a specific order
        header = [
            "library",
            "mapped",
            "dedup_mapped",
            "restricted_mapped",
            "library_size",
            "percent_duplication",
            "insert_size",
        ]

        with open(output.txt, "w") as f:
            print(*header, sep="\t", file=f)
            for stats_file in input:
                summary = parse_stats_fields(stats_file)
                row = [summary[k] for k in header]
                print(*row, sep="\t", file=f)


rule compute_effective_genome_size:
    output:
        txt="genome_size.txt"
    input:
        fasta=config["reference_fasta"]
    run:
        with open(output.txt, "w") as f:
            print(compute_genome_size(input.fasta), file=f)


rule samtools_index:
    output:
        "{name}.bai"
    input:
        "{name}.bam"
    shell:
        "samtools index {input} {output}"


rule samtools_idxstats:
    output:
        txt="{name}.idxstats.txt"
    input:
        bam="{name}.bam",
        bai="{name}.bai",
    shell:
        "samtools idxstats {input.bam} > {output.txt}"


rule samtools_flagstat:
    output:
        txt="{name}.flagstat.txt"
    input:
        bam="{name}.bam"
    shell:
        "samtools flagstat {input.bam} > {output.txt}"
