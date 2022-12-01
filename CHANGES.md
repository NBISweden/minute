# minute Changelog

## v0.2.0

### Bug fixes

* Recover missing rows from Statistics Summary table on the MultiQC report when
a sample is mapped to more than one reference.
* Issue #159: Pin snakemake version to 7.16. 

### Features

* Improved MultiQC reporting by adding:
	- Picard `CollectInsertSizeMetrics` figure.
	- Custom library complexity estimate based on Picard, adapted to use the
	single-end numbers from Je.
	- Number of demultiplexed reads per sample.
	- Reorder tables on MultiQC report (Statistics Summary first).

### Other

* Minor numerical formatting changes on final stats summary tables.