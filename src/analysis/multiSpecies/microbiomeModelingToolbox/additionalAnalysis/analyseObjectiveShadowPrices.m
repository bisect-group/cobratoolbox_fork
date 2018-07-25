function [ShadowPrices]=analyseObjectiveShadowPrices(modelList,objectiveList,varargin)
% This function determines the shadow prices indicating metabolites that 
% are relevant for the flux through one or multiple objective functions
% optimized in one or more COBRA model structures. The objective functions
% entered are optimized one by one. By default, all metabolites with
% nonzero shadow prices are extracted from the computed flux solutions. The
% function was wirtten for the Microbiome Modeling Toolbox but can be used
% for any COBRA model structure(s) and objective function(s).
% When used with the Microbiome Modeling Toolbox, this function should be
% used after running mgPipe and determining metabolites of interest that
% are stratifying the modeled personalized microbiomes. The fecal exchanges 
% secreting the metabolites of interest (e.g., EX_co2[fe]) should be used 
% as the objective functions entered in the present function to determine
% model compounds that have value for the secretion of the metabolite of
% interest.
%
% USAGE:
% [ShadowPrices]=analyseObjectiveShadowPrices(modelList,objectiveList,varargin)
%
% REQUIRED INPUTS:
% modelList         Cell array containing one or more COBRA model
%                   structures in vertical order
% objectiveList     Cell array containing the names of one or more
%                   objective functions of interest in vertical order
% OPTIONAL INPUTS:
% modelIDs          Cell array containing IDs of the models displayed in 
%                   the output table in same order as corresponding models
%                   (default IDs assigned if not entered)
% osenseStr         String indicating whether objective function(s)
%                   should be maximized or minimized. Allowed inputs:
%                   'min','max', default:'max'.
% SPDef             String indicating whether positive, negative, or
%                   all nonzero shadow prices should be collected. 
%                   Allowed inputs: 'Positive','Negative','Nonzero',
%                   default: 'Nonzero'.
% numWorkers        Number indicating number of workers in parallel pool
%                   (default: 0).
%
% OUTPUT:
% ShadowPrices      Table with shadow prices for metabolites that are 
%                   relevant for each analyzed objective in each analyzed
%                   model
% 
% Author:
%-Almut Heinken, 07/2018

parser = inputParser();  % Define default input parameters if not specified
parser.addRequired('modelList', @iscell);
parser.addRequired('objectiveList', @iscell);
parser.addParameter('modelIDs',{}, @iscell);
parser.addParameter('osenseStr','max', @ischar);
parser.addParameter('SPDef','Nonzero', @ischar);
parser.addParameter('numWorkers', 0, @(x) isnumeric(x))
parser.parse(modelList,objectiveList, varargin{:})

modelList = parser.Results.modelList;
objectiveList = parser.Results.objectiveList;
modelIDs = parser.Results.modelIDs;
numWorkers = parser.Results.numWorkers;
SPDef = parser.Results.SPDef;
if isempty(modelIDs)
    for i=1:size(modelList,1)
        modelIDs{i,1}=strcat('model_',num2str(i));
    end
end

% set a solver if not done already
global CBT_LP_SOLVER
solver = CBT_LP_SOLVER;
if isempty(solver)
    initCobraToolbox;
    solver = CBT_LP_SOLVER;
end
% initialize parallel pool
if numWorkers > 0
    % with parallelization
    poolobj = gcp('nocreate');
    if isempty(poolobj)
        parpool(numWorkers)
    end
end
ShadowPrices{1,1}='Metabolite';
ShadowPrices{1,2}='Objective';

% Compute the solutions for all entered models and objective functions
solutions={};
if numWorkers > 0
    % with parallelization
    parfor i=1:size(modelList,1)
        i
        ShadowPrices{1,i+2}=modelIDs{i,1};
        model=modelList{i,1};
        if osenseStr=='max'
            model.osenseStr='max';
        elseif osenseStr=='min'
            model.osenseStr='min';
        end
        changeCobraSolver(solver, 'LP');
        solutionsTemp={};
        % Compute the solutions for all objectives
        for j=1:size(objectiveList,1)
            % optimize for the objective if it is present in the model
            if ~isempty(find(ismember(model.rxns,objectiveList{j,1})))
            model=changeObjective(model,objectiveList{j,1});
            FBAsolution=solveCobraLP(model);
            solutionsTemp{j,1}=FBAsolution;
            end
        end
        solutions(:,i)=solutionsTemp;
    end
else
    % without parallelization
    for i=1:size(modelList,1)
        ShadowPrices{1,i+2}=modelIDs{i,1};
        model=modelList{i,1};
        % Compute the solutions for all objectives
        for j=1:size(objectiveList,1)
            % optimize for the objective if it is present in the model
            if ~isempty(find(ismember(model.rxns,objectiveList{j,1})))
                model=changeObjective(model,objectiveList{j,1});
                FBAsolution=solveCobraLP(model);
                solutions{j,i}=FBAsolution;
            end
        end
    end
end
% Extract all shadow prices and save them in a table
for i=1:size(modelList,1)
    model=modelList{i,1};
    for j=1:size(objectiveList,1)
        % get the computed solutions
        if ~isempty(solutions{j,i})
            FBAsolution=solutions{j,i};
            % verify that a feasible solution was obtained
            if FBAsolution.stat==1
                [extractedShadowPrices]=extractShadowPrices(model,FBAsolution,SPDef);
                for k=1:size(extractedShadowPrices,1)
                    % check if the metabolite relevant for this objective
                    % function is already in the table
                    findMet=find(strcmp(ShadowPrices(:,1),extractedShadowPrices{k,1}));
                    findObj=find(strcmp(ShadowPrices(:,2),objectiveList{j,1}));
                    if ~isempty(intersect(findMet,findObj))
                        % Add the shadow price for this model
                        ShadowPrices{intersect(findMet,findObj),i+2}=extractedShadowPrices{k,2};
                    else
                        % Add a new row for this metabolite and objective function with the shadow price for this model
                        newRow=size(ShadowPrices,1)+1;
                        ShadowPrices{newRow,1}=extractedShadowPrices{k,1};
                        ShadowPrices{newRow,2}=objectiveList{j,1};
                        ShadowPrices{newRow,i+2}=extractedShadowPrices{k,2};
                    end
                end
            end
        end
    end
end
end

function [extractedShadowPrices]=extractShadowPrices(model,FBAsolution,SPDef)
% Finds all shadow prices in a solution computed for a COBRA model
% structure that indicate the metabolite is relevant for the flux through the objective function.

extractedShadowPrices={};
% Find all shadow prices (negative or positive depending on variable
% SPDef)
cnt=1;
for i=1:length(model.mets)
    % Do not include slack variables
    if ~strncmp('slack_',model.mets{i},6)
        if strcmp(SPDef,'Negative')
            if FBAsolution.dual(i)  <0 && abs(FBAsolution.dual(i))>0.00000001
                extractedShadowPrices{cnt,1}=model.mets{i};
                extractedShadowPrices{cnt,2}=FBAsolution.dual(i);
                cnt=cnt+1;
            end
        elseif strcmp(SPDef,'Positive')
            if FBAsolution.dual(i)  >0 && abs(FBAsolution.dual(i))>0.00000001
                extractedShadowPrices{cnt,1}=model.mets{i};
                extractedShadowPrices{cnt,2}=FBAsolution.dual(i);
                cnt=cnt+1;
            end
        elseif strcmp(SPDef,'Nonzero')
            if FBAsolution.dual(i)  ~=0 && abs(FBAsolution.dual(i))>0.00000001
                extractedShadowPrices{cnt,1}=model.mets{i};
                extractedShadowPrices{cnt,2}=FBAsolution.dual(i);
                cnt=cnt+1;
            end
        end
    end
end
end
