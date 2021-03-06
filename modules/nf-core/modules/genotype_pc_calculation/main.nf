
process GENOTYPE_PC_CALCULATION {
    tag "${samplename}.${sample_subset_file}"
    label 'process_medium'
    publishDir "${params.outdir}/subset_genotype/", mode: "${params.copy_mode}", pattern: "${samplename}.${sample_subset_file}.subset.vcf.gz"
    
    
    if (workflow.containerEngine == 'singularity' && !params.singularity_pull_docker_container) {
        container "/software/hgi/containers/eqtl.img"
    } else {
        log.info 'change the docker container - this is not the right one'
        container "quay.io/biocontainers/multiqc:1.10.1--py_0"
    }


    input:
        path(plink_bed)

    output:
    
        path("gtpca_plink.eigenvec"), emit: gtpca_plink

    script:

        """
            plink2 --freq counts --bfile ${plink_bed}/plink_genotypes --out tmp_gt_plink_freq
            plink2 --pca --read-freq tmp_gt_plink_freq.acount  --bfile ${plink_bed}/plink_genotypes --out gtpca_plink
        """
}
