// Pipeline para terraform: plan + apply (con aprobación manual) o destroy.
// Usa el Terraform Plugin de Jenkins (tool 'terraform') — el binario lo
// instala/cachea Jenkins en el agente automáticamente.

pipeline {
    agent { label 'agent-1' }

    parameters {
        choice(
            name: 'STACK',
            choices: ['shared', 'bots/faitpro-bot'],
            description: 'Stack a aplicar (carpeta dentro del repo)'
        )
        choice(
            name: 'ACTION',
            choices: ['plan', 'apply', 'destroy'],
            description: 'plan = solo muestra cambios; apply = plan + approval + apply; destroy = plan -destroy + approval + destroy'
        )
        booleanParam(
            name: 'AUTO_APPROVE',
            defaultValue: false,
            description: 'Saltea el approval manual (peligroso, usar solo para automatización)'
        )
    }

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
    }

    environment {
        AWS_CREDS_ID     = 'aws-terraform'
        AWS_REGION       = 'us-east-1'
        TF_IN_AUTOMATION = 'true'
        TF_INPUT         = 'false'
    }

    stages {

        stage('Validate stack path') {
            steps {
                script {
                    if (!fileExists("${params.STACK}/backend.tf")) {
                        error "Stack '${params.STACK}' no existe o le falta backend.tf"
                    }
                    echo "Stack:  ${params.STACK}"
                    echo "Action: ${params.ACTION}"
                }
            }
        }

        stage('Terraform plan') {
            steps {
                script {
                    def tfHome = tool name: 'terraform', type: 'org.jenkinsci.plugins.terraform.TerraformInstallation'
                    withEnv(["PATH+TERRAFORM=${tfHome}"]) {
                        withCredentials([usernamePassword(
                            credentialsId: env.AWS_CREDS_ID,
                            usernameVariable: 'AWS_ACCESS_KEY_ID',
                            passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                        )]) {
                            def destroyFlag = params.ACTION == 'destroy' ? '-destroy' : ''
                            dir(params.STACK) {
                                sh "terraform version"
                                sh "terraform init -input=false"
                                sh "terraform validate"
                                sh "terraform plan ${destroyFlag} -out=tfplan -input=false"
                                sh "terraform show -no-color tfplan > plan.txt"
                            }
                        }
                    }
                }
                archiveArtifacts artifacts: "${params.STACK}/plan.txt", fingerprint: false, onlyIfSuccessful: true
            }
        }

        stage('Approval') {
            when {
                allOf {
                    expression { params.ACTION in ['apply', 'destroy'] }
                    expression { !params.AUTO_APPROVE }
                }
            }
            steps {
                script {
                    def planSummary = readFile("${params.STACK}/plan.txt")
                    def lines = planSummary.readLines()
                    def tail = lines.size() > 80 ? lines[-80..-1].join('\n') : planSummary
                    input message: "Aplicar ${params.ACTION} a ${params.STACK}?",
                          parameters: [text(name: 'plan_tail', defaultValue: tail, description: 'Últimas 80 líneas del plan')]
                }
            }
        }

        stage('Terraform apply / destroy') {
            when { expression { params.ACTION in ['apply', 'destroy'] } }
            steps {
                script {
                    def tfHome = tool name: 'terraform', type: 'org.jenkinsci.plugins.terraform.TerraformInstallation'
                    withEnv(["PATH+TERRAFORM=${tfHome}"]) {
                        withCredentials([usernamePassword(
                            credentialsId: env.AWS_CREDS_ID,
                            usernameVariable: 'AWS_ACCESS_KEY_ID',
                            passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                        )]) {
                            dir(params.STACK) {
                                sh "terraform apply -input=false tfplan"
                            }
                        }
                    }
                }
            }
        }
    }

    post {
        success {
            echo "${params.ACTION} de ${params.STACK} completado"
        }
        failure {
            echo "${params.ACTION} de ${params.STACK} fallido"
        }
        always {
            sh "rm -f ${params.STACK}/tfplan ${params.STACK}/plan.txt || true"
            cleanWs()
        }
    }
}
