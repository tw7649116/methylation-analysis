SHELL=/bin/bash -o pipefail

##################################################
#
# Step 0. Preamble: set up paths, variables and
#         install software.
#
##################################################

# do not leave failed files around
.DELETE_ON_ERROR:

# do not delete intermediate files
.SECONDARY:

# Parameters to control execution
THREADS=4

# Path to this file
ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

# Install samtools
samtools.version:
	git clone --recursive https://github.com/samtools/htslib.git
	cd htslib; git checkout 1.2.1; make
	git clone --recursive https://github.com/samtools/samtools.git
	cd samtools; git checkout 1.2; make
	-cd samtools; git log | head -1 > ../$@

# Install bwa
bwa.version:
	git clone https://github.com/lh3/bwa.git
	cd bwa; make
	-cd bwa; git log | head -1 > ../$@

# Install python libs
pythonlibs.version:
	pip install biopython >> $@
	pip freeze >> $@

# Install bedtools
bedtools.version:
	git clone https://github.com/arq5x/bedtools2.git bedtools
	cd bedtools; make
	-cd bedtools; git log | head -1 > ../$@

# timestamp for saving different versions of plots
# http://stackoverflow.com/questions/12463770/insert-time-stamp-into-executable-name-using-makefile
NOW := $(shell date +'%y.%m.%d_%H:%M:%S')

##################################################
#
# Step 1. Prepare input data 
#
##################################################

# Convert a directory of FAST5 files to fasta using poretools
%.fasta: %.fast5
	poretools fasta --type 2D $</ > $@

# Index a reference genome with BWA
%.fasta.bwt: %.fasta bwa.version
	bwa/bwa index $<

# Set convenience variables for the data we'll use to train the model
TRAINING_FASTA=M.SssI.e2925_ecoli.fasta
TRAINING_CONTROL_FASTA=ERX708228.ecoli.fasta
TRAINING_REFERENCE=ecoli_k12.fasta

TRAINING_BAM=$(TRAINING_FASTA:.fasta=.sorted.bam)
TRAINING_CONTROL_BAM=$(TRAINING_CONTROL_FASTA:.fasta=.sorted.bam)

# ...and for the test data
TEST_FASTA=M.SssI.lambda.fasta
TEST_CONTROL_FASTA=control.lambda.fasta
TEST_REFERENCE=lambda.reference.fasta

TEST_BAM=$(TEST_FASTA:.fasta=.sorted.bam)
TEST_CONTROL_BAM=$(TEST_CONTROL_FASTA:.fasta=.sorted.bam)

##################################################
#
# Step 2. Align each data set to its reference
#
##################################################

# lambda data sets
%.lambda.sorted.bam: %.lambda.fasta lambda.reference.fasta lambda.reference.fasta.bwt bwa.version samtools.version
	make -f $(ROOT_DIR)/alignment.make OUTPUT=$@ \
                                       READS=$< \
                                       REFERENCE=lambda.reference.fasta \
                                       THREADS=$(THREADS) \
                                       BWA=bwa/bwa \
                                       SAMTOOLS=samtools/samtools

# ecoli data set, we align to K12 since we don't have a e2925 reference
%ecoli.sorted.bam: %ecoli.fasta ecoli_k12.fasta ecoli_k12.fasta.bwt bwa.version samtools.version
	make -f $(ROOT_DIR)/alignment.make OUTPUT=$@ \
                                       READS=$< \
                                       REFERENCE=ecoli_k12.fasta \
                                       THREADS=$(THREADS) \
                                       BWA=bwa/bwa \
                                       SAMTOOLS=samtools/samtools

# human data set 
ProHum20kb.sorted.bam: ProHum20kb.fasta human_g1k_v37.fasta human_g1k_v37.fasta.bwt bwa.version samtools.version
	make -f $(ROOT_DIR)/alignment.make OUTPUT=$@ \
                                       READS=$< \
                                       REFERENCE=human_g1k_v37.fasta \
                                       THREADS=$(THREADS) \
                                       BWA=bwa/bwa \
                                       SAMTOOLS=samtools/samtools

%.bam.bai: %.bam
	samtools/samtools index $<

##################################################
#
# Step 3. Train the methylation model
#
##################################################

# Convert all CG dinucleotides of the reference genome to MG for training
$(TRAINING_REFERENCE).methylated: $(TRAINING_REFERENCE) pythonlibs.version
	python $(ROOT_DIR)/methylate_reference.py $< > $@

# Initialize methylation models from the base models
%.model.initial_methyl: %.model
	python $(ROOT_DIR)/methylate_model.py $< > $@

# Make a fofn of the initialized methylation models    
initial_methyl_models.fofn: r7.3_template_median68pA.model.initial_methyl r7.3_complement_median68pA_pop1.model.initial_methyl r7.3_complement_median68pA_pop2.model.initial_methyl
	echo $^ | tr " " "\n" > $@

# As a side effect of this program, we get trained methylation model in the *.methyltrain files
r7.3_template_median68pA.model.methyltrain: $(TRAINING_BAM) $(TRAINING_BAM:.bam=.bam.bai) $(TRAINING_FASTA) $(TRAINING_REFERENCE).methylated initial_methyl_models.fofn
	nanopolish/nanopolish methyltrain -t $(THREADS) \
                                      -m initial_methyl_models.fofn \
                                      -b $(TRAINING_BAM) \
                                      -r $(TRAINING_FASTA) \
                                      -g $(TRAINING_REFERENCE).methylated \
                                      -w "gi|556503834|ref|NC_000913.3|:50000-70000"

# Run methyltrain on unmethylated data to get data to compare to
$(TRAINING_CONTROL_BAM).training.0.tsv: $(TRAINING_CONTROL_BAM) $(TRAINING_CONTROL_BAM:.bam=.bam.bai) $(TRAINING_CONTROL_FASTA) $(TRAINING_REFERENCE) initial_methyl_models.fofn
	nanopolish/nanopolish methyltrain -t $(THREADS) \
                                      -m initial_methyl_models.fofn \
                                      --no-update-models \
                                      -b $(TRAINING_CONTROL_BAM) \
                                      -r $(TRAINING_CONTROL_FASTA) \
                                      -g $(TRAINING_REFERENCE) \
                                      -w "gi|556503834|ref|NC_000913.3|:50000-70000"

# Make a fofn of the trained methylation models 
trained_methyl_models.fofn: r7.3_template_median68pA.model.methyltrain r7.3_complement_median68pA_pop1.model.methyltrain r7.3_complement_median68pA_pop2.model.methyltrain
	echo $^ | tr " " "\n" > $@

# Make training plots
training_plots.pdf: r7.3_template_median68pA.model.methyltrain $(TRAINING_CONTROL_BAM).methyltrain.0.tsv
	Rscript $(ROOT_DIR)/methylation_plots.R training_plots
	cp $@ $@.$(NOW)

##################################################
#
# Step 4. Test the methylation model
#
##################################################
%.methyltest: % %.bai $(TEST_REFERENCE) trained_methyl_models.fofn
	$(eval TMP_BAM := $<)
	nanopolish/nanopolish methyltest  -t 1 \
                                      -m trained_methyl_models.fofn \
                                      -b $(TMP_BAM) \
                                      -r $(TMP_BAM:.sorted.bam=.fasta) \
                                      -g $(TEST_REFERENCE) > $@

%.sites: %
	grep SITE $< > $@

%.read: %
	grep READ $< > $@

site_likelihood_plots.pdf: M.SssI.lambda.sorted.bam.methyltest.sites
	Rscript $(ROOT_DIR)/methylation_plots.R site_likelihood_plots
	cp $@ $@.$(NOW)

read_classification_plot.pdf: M.SssI.lambda.sorted.bam.methyltest.read control.lambda.sorted.bam.methyltest.read
	Rscript $(ROOT_DIR)/methylation_plots.R read_classification_plot
	cp $@ $@.$(NOW)

##################################################
#
# Step 5. Human genome analysis
#
##################################################

# Download database of CpG islands from Irizarry's method
irizarry.cpg_islands.bed:
	wget http://rafalab.jhsph.edu/CGI/model-based-cpg-islands-hg19.txt
	cat model-based-cpg-islands-hg19.txt | grep -v length > $@

# Annotate the CpG islands with whether they are <= 2kb upstream of a gene
irizarry.cpg_islands.genes.bed: irizarry.cpg_islands.bed gencode_genes_2kb_upstream.bed
	bedtools/bin/bedtools map -o first -c 4 -a <(cat irizarry.cpg_islands.bed | bedtools/bin/bedtools sort) \
                                            -b <(cat gencode_genes_2kb_upstream.bed | bedtools/bin/bedtools sort) > $@

# Download a bed file summarizing an NA12878 bisulfite experiment from ENCODE
ENCFF257GGV.bed:
	wget https://www.encodeproject.org/files/ENCFF257GGV/@@download/ENCFF257GGV.bed.gz
	gunzip ENCFF257GGV.bed.gz

# Run methyltest on the human data to score CpG sites
ProHum20kb.sorted.bam.methyltest: ProHum20kb.sorted.bam ProHum20kb.sorted.bam.bai trained_methyl_models.fofn
	$(eval TMP_BAM := $<)
	nanopolish/nanopolish methyltest  -t 1 \
                                      -m trained_methyl_models.fofn \
                                      -b $(TMP_BAM) \
                                      -r $(TMP_BAM:.sorted.bam=.fasta) \
                                      -g human_g1k_v37.fasta > $@

# Extract the CpG sites to a bed file
ProHum20kb.sorted.bam.methyltest.sites.bed: ProHum20kb.sorted.bam.methyltest
	$(ROOT_DIR)/human_sites_to_bed.sh $< > $@

# Calculate a summary score for each CpG island from the ONT reads
ProHum20kb.ont_score.cpg_islands: irizarry.cpg_islands.genes.bed ProHum20kb.sorted.bam.methyltest.sites.bed bedtools.version
	bedtools/bin/bedtools intersect -wb -b irizarry.cpg_islands.genes.bed -a ProHum20kb.sorted.bam.methyltest.sites.bed | \
        python $(ROOT_DIR)/calculate_ont_signal_for_cpg_islands.py > $@

# Calculate a summary score for each CpG island from the bisulfite data
NA12878.bisulfite_score.cpg_islands: irizarry.cpg_islands.genes.bed ENCFF257GGV.bed bedtools.version
	bedtools/bin/bedtools intersect -wb -b irizarry.cpg_islands.genes.bed -a ENCFF257GGV.bed | \
        python $(ROOT_DIR)/calculate_bisulfite_signal_for_cpg_islands.py > $@

human_cpg_island_plot.pdf: NA12878.bisulfite_score.cpg_islands ProHum20kb.ont_score.cpg_islands
	Rscript $(ROOT_DIR)/methylation_plots.R human_cpg_island_plot $^
	cp $@ $@.$(NOW)
