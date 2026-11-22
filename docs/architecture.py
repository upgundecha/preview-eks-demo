"""Generates docs/architecture.png. Requires Graphviz and `pip install diagrams`.

Run from the repo root: python docs/architecture.py
"""
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EKS, ECR
from diagrams.aws.network import ALB, Route53, NATGateway
from diagrams.aws.security import ACM, IAMRole
from diagrams.aws.storage import EBS
from diagrams.k8s.network import Ing
from diagrams.k8s.podconfig import Secret
from diagrams.k8s.storage import PVC
from diagrams.onprem.client import Users
from diagrams.onprem.gitops import ArgoCD
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.vcs import Github
from diagrams.onprem.ci import GithubActions
from diagrams.programming.language import Java
from diagrams.programming.framework import React

graph_attr = {"fontsize": "22", "pad": "0.5", "nodesep": "0.6", "ranksep": "0.9", "splines": "spline"}

with Diagram(
    "Feature branch previews on Amazon EKS with Argo CD",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
):
    users = Users("Reviewers\npr-N.preview.<domain>")

    with Cluster("GitHub"):
        repo = Github("Repo + PR\n'preview' label")
        actions = GithubActions("Actions\ntest, build, verify")

    with Cluster("AWS account (region)"):
        oidc = IAMRole("GitHub OIDC role\n(ECR push only)")
        ecr = ECR("ECR web / api\npr-N-<sha> (immutable)")
        r53 = Route53("Route 53\npreview zone")
        acm = ACM("ACM wildcard\n*.preview.<domain>")

        with Cluster("VPC (2 AZs)"):
            with Cluster("Public subnets"):
                alb = ALB("Shared ALB\nIngressGroup")
                nat = NATGateway("NAT gateway")

            with Cluster("Private subnets: EKS cluster (managed node group)"):
                with Cluster("argocd"):
                    argo = ArgoCD("Argo CD\nApplicationSet\n(PR generator)")

                with Cluster("kube-system / add-ons"):
                    lbc = EKS("AWS Load Balancer\nController")
                    edns = EKS("ExternalDNS\n(IRSA)")
                    eso = EKS("External Secrets\nOperator")

                with Cluster("Namespace preview-N (one per PR)"):
                    ing = Ing("Ingress")
                    web = React("web\n(nginx + React)")
                    api = Java("api\n(Spring Boot)")
                    db = PostgreSQL("PostgreSQL")
                    pvc = PVC("PVC")
                    sec = Secret("DB password\n(ESO generated)")

            ebs = EBS("EBS gp3")

    # CI path (push-only, no cluster credentials)
    repo >> Edge(label="PR event") >> actions
    actions >> Edge(label="assume role") >> oidc
    actions >> Edge(label="push images") >> ecr
    actions >> Edge(label="add label", style="dashed") >> repo

    # GitOps pull path
    argo >> Edge(label="poll PRs (60s)\n+ chart from main", style="dashed", color="darkorange") >> repo
    argo >> Edge(label="sync Helm release", color="darkorange") >> ing
    ecr >> Edge(label="nodes pull images\nvia NAT", style="dotted") >> nat

    # Add-ons
    lbc >> Edge(label="reconcile rules") >> alb
    edns >> Edge(label="pr-N record") >> r53
    eso >> sec
    acm >> Edge(label="TLS") >> alb

    # Request path
    users >> Edge(label="DNS", style="dashed") >> r53
    users >> Edge(label="HTTPS", color="darkgreen") >> alb
    alb >> Edge(color="darkgreen") >> ing
    ing >> Edge(label="/", color="darkgreen") >> web
    ing >> Edge(label="/api", color="darkgreen") >> api
    api >> Edge(color="darkgreen") >> db
    sec >> api
    db >> pvc >> ebs

