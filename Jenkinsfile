// Pipeline para terraform: plan + apply (con aprobación manual) o destroy.
// Corre terraform dentro de un container hashicorp/terraform usando el plugin
// docker-workflow (docker.image().inside()), que maneja el path mapping
// correcto incluso con docker-out-of-docker.

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
        AWS_CREDS_ID  = 'aws-terraform'
        AWS_REGION    = 'us-east-1'
        TF_IMAGE      = 'hashicorp/terraform:1.15'
        TF_IN_AUTOMATION = 'true'
        TF_INPUT      = 'false'
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
                withCredentials([usernamePassword(
                    credentialsId: env.AWS_CREDS_ID,
                    usernameVariable: 'AWS_ACCESS_KEY_ID',
                    passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                )]) {
                    script {
                        def destroyFlag = params.ACTION == 'destroy' ? '-destroy' : ''
                        docker.image(env.TF_IMAGE).inside('--entrypoint=""') {
                            sh """
                                cd '${params.STACK}'
                                terraform init -input=false
                                terraform validate
                                terraform plan ${destroyFlag} -out=tfplan -input=false
                                terraform show -no-color tfplan > plan.txt
                            """
                        }
                    }
                    archiveArtifacts artifacts: "${params.STACK}/plan.txt", fingerprint: false, onlyIfSuccessful: true
                }
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
                withCredentials([usernamePassword(
                    credentialsId: env.AWS_CREDS_ID,
                    usernameVariable: 'AWS_ACCESS_KEY_ID',
                    passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                )]) {
                    script {
                        docker.image(env.TF_IMAGE).inside('--entrypoint=""') {
                            sh """
                                cd '${params.STACK}'
                                terraform apply -input=false tfplan
                            """
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
