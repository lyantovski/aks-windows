@{
    SubscriptionId = '<azure-subscription-id>'
    ResourceGroup = '<aks-resource-group>'
    ClusterName = '<aks-cluster-name>'
    KubectlContext = '<kubectl-context>'

    RegistryName = '<acr-name>'
    RegistryLoginServer = '<acr-name>.azurecr.io'

    RuntimeSource = 'docker.io/dockurr/windows@sha256:<runtime-image-digest>'
    RuntimeRepository = 'windows/runtime'

    TransferRepository = 'windows/transfer'
    TransferTag = '1.0.0'

    ArtifactRepository = 'windows/golden-disk'
    ArtifactTag = 'windows-11-v1'

    SourceNamespace = 'windows'
    SourcePvc = 'windows-pvc'

    TargetNamespace = 'windows-imported'
    TargetPvc = 'windows-pvc'

    StorageClass = 'default'
    StorageSize = '64Gi'
    StagingSize = '64Gi'
    DiskSize = '64G'
    Replicas = 1
}
