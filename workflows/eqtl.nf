/*
========================================================================================
    VALIDATE INPUTS
========================================================================================
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters
// WorkflowEqtl.initialise(params, log)

// TODO nf-core: Add all file path parameters for the pipeline to the list below
// Check input path parameters to see if they exist
// def checkPathParamList = [ params.input, params.multiqc_config, params.fasta ]
// for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

// // Check mandatory parameters
// if (params.input) { ch_input = file(params.input) } else { exit 1, 'Input samplesheet not specified!' }

/*
========================================================================================
    CONFIG FILES
========================================================================================
*/

ch_multiqc_config        = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config) : Channel.empty()

/*
========================================================================================
    IMPORT LOCAL MODULES/SUBWORKFLOWS
========================================================================================
*/

// Don't overwrite global params.modules, create a copy instead and use that within the main script.
def modules = params.modules.clone()

//
// MODULE: Local to the pipeline
//

/*
========================================================================================
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
========================================================================================
*/

def multiqc_options   = modules['multiqc']
multiqc_options.args += params.multiqc_title ? Utils.joinModuleArgs(["--title \"$params.multiqc_title\""]) : ''

//
// MODULE: Installed directly from nf-core/modules
//
// include { FASTQC  } from '../modules/nf-core/modules/fastqc/main'  addParams( options: modules['fastqc'] )
include {PREPROCESS_GENOTYPES} from '../modules/nf-core/modules/preprocess_genotypes/main' 
include {PLINK_CONVERT} from '../modules/nf-core/modules/plink_convert/main' 
include {SUBSET_GENOTYPE} from '../modules/nf-core/modules/subset_genotype/main' 
include {KINSHIP_CALCULATION} from '../modules/nf-core/modules/kinship_calculation/main' 
include {GENOTYPE_PC_CALCULATION} from '../modules/nf-core/modules/genotype_pc_calculation/main' 
include {SPLIT_PHENOTYPE_DATA} from '../modules/nf-core/modules/split_phenotype_data/main' 
include {NORMALISE_and_PCA_PHENOTYPE} from '../modules/nf-core/modules/normalise_and_pca/main' 
include {LIMIX_eqtls} from '../modules/nf-core/modules/limix/main'
include {PREPROCESS_SAMPLE_MAPPING} from '../modules/nf-core/modules/preprocess_sample_mapping/main'
include {AGGREGATE_UMI_COUNTS} from '../modules/nf-core/modules/aggregate_UMI_counts/main'
include {CHUNK_GENOME} from '../modules/nf-core/modules/chunk_genome/main'
include {PREPERE_EXP_BED} from '../modules/nf-core/modules/prepere_exp_bed/main'
include {TENSORQTL_eqtls} from '../modules/nf-core/modules/tensorqtl/main'
/*
========================================================================================
    RUN MAIN WORKFLOW
========================================================================================
*/

// Info required for completion email and summary
def multiqc_report = []

workflow EQTL {

    log.info 'Lets run eQTL mapping'
    donorsvcf = Channel.from(params.input_vcf)
    // if single cell data then have to prepere pseudo bulk dataset.
    if (params.method=='bulk'){
        genotype_phenotype_mapping_file=params.genotype_phenotype_mapping_file
        phenotype_file=params.phenotype_file

        input_channel = Channel.fromPath(genotype_phenotype_mapping_file, followLinks: true, checkIfExists: true)
        
        input_channel.splitCsv(header: true, sep: params.input_tables_column_delimiter)
            .map{row->tuple(row.Genotype)}.distinct()
            .set{channel_input_data_table}
        input_channel.splitCsv(header: true, sep: params.input_tables_column_delimiter)
            .map{row->row.Sample_Category}.set{condition_channel}


    }else if (params.method=='single_cell'){
        AGGREGATE_UMI_COUNTS(params.phenotype_file,params.aggregation_collumn,params.n_min_cells,params.n_min_individ)
        genotype_phenotype_mapping_file = AGGREGATE_UMI_COUNTS.out.genotype_phenotype_mapping
        phenotype_file= AGGREGATE_UMI_COUNTS.out.phenotype_file
        genotype_phenotype_mapping_file.splitCsv(header: true, sep: params.input_tables_column_delimiter)
            .map{row->tuple(row.Genotype)}.distinct()
            .set{channel_input_data_table}

        genotype_phenotype_mapping_file.splitCsv(header: true, sep: params.input_tables_column_delimiter)
            .map{row->row.Sample_Category}.set{condition_channel}

    }

    channel_input_data_table=channel_input_data_table.unique()
    SUBSET_GENOTYPE(donorsvcf,channel_input_data_table.collect())
    // // // // For ext mapping there are multiple steps - 
    // // // // 1) Filter the vcf accordingly
    PREPROCESS_GENOTYPES(SUBSET_GENOTYPE.out.samplename_subsetvcf)
    // // // // // 2) Generate the PLINK file
    PLINK_CONVERT(PREPROCESS_GENOTYPES.out.filtered_vcf)
    // // // 3) Generate the kinship matrix and genotype PCs
    KINSHIP_CALCULATION(PLINK_CONVERT.out.plink_path)
    GENOTYPE_PC_CALCULATION(PLINK_CONVERT.out.plink_path)
    
    condition_channel = condition_channel.unique() 

    // 4) Phenotype file preperation including PCs, normalisation
    genome_annotation = Channel.from(params.annotation_file)
    // Prepeare chunking file
    
    // MBV method from QTLTools (PMID 28186259)  
    // // condition_channel.view()    
    // RASCAL
    // 
    SPLIT_PHENOTYPE_DATA(genotype_phenotype_mapping_file,phenotype_file,condition_channel)

    NORMALISE_and_PCA_PHENOTYPE(SPLIT_PHENOTYPE_DATA.out.phenotye_file,genotype_phenotype_mapping_file)

    CHUNK_GENOME(genome_annotation,NORMALISE_and_PCA_PHENOTYPE.out.filtered_phenotype)
    // if scRNA Take an anndata object with annotations and tell which condition is an agregation row. 
    
    PREPROCESS_SAMPLE_MAPPING(genotype_phenotype_mapping_file)
    
    PREPERE_EXP_BED(NORMALISE_and_PCA_PHENOTYPE.out.for_bed,params.annotation_file,GENOTYPE_PC_CALCULATION.out.gtpca_plink)

    // PREPERE_COVARIATES_FILE(GENOTYPE_PC_CALCULATION.out.gtpca_plink,)

    if (params.LIMIX.run){
        LIMIX_eqtls(
        CHUNK_GENOME.out.limix_condition_chunking,
        PLINK_CONVERT.out.plink_path,
        KINSHIP_CALCULATION.out.kinship_matrix,
        PREPROCESS_SAMPLE_MAPPING.out.genotype_phenotype,
        CHUNK_GENOME.out.filtered_chunking_file
        )
    }

    if (params.TensorQTL.run){
        TENSORQTL_eqtls(
            PREPERE_EXP_BED.out.exp_bed,
            PLINK_CONVERT.out.plink_path,
        )
    }


    // Then run a LIMIX and/or TensorQTL - here have to combine the inputs.
    
    // Generate plots of comparisons of eQTLs detected by both methods.


}

/*
========================================================================================
    COMPLETION EMAIL AND SUMMARY
========================================================================================
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
}

/*
========================================================================================
    THE END
========================================================================================
*/
